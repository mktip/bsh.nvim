-- The execution substrate: build a command's argv, run it async, stream its
-- output (inline into the cell's fence, or into a side buffer), and the small
-- runners `run_shell` / `run_oneshot` on top. Sits on bsh.fence (extmark/fence
-- state) and bsh.config (options).
local M = {}

local fence = require("bsh.fence")
local config = require("bsh.config")
local ns, inflight = fence.ns, fence.inflight
local stage_fence = fence.stage_fence

-- ───────────────────────────── targets as routes ────────────────────────────
-- A target is a ROUTE: `scheme@addr` hops chained with `/`, read left = OUTERMOST
-- (outside-in, big -> small: `web@prod/docker@api` = host `prod`, then *into*
-- container `api`). Each hop's transport is a small argv TEMPLATE
-- (config.transports), so reaching into a container/jail/VM is user-definable --
-- the engine hardcodes nothing but ssh.
--   `web@prod`        -> ssh (scheme `web` isn't a transport -> whole seg is the
--                        ssh destination; back-compatible with the old behaviour)
--   `docker@api`      -> config.transports.docker template, addr `api`
--   `web@prod/docker@api` -> ssh hop (outer) wrapping a docker hop (inner)
-- ssh runs a *login* shell so the remote profile loads (PATH/env); -T = no pty
-- (we capture non-interactively, stdin closed -> auth must be non-interactive).

-- The built-in ssh hop (depends on remote_login). `{cmd}` is embedded in a word
-- the REMOTE shell re-parses, so it gets shell-escaped (see subst).
local function ssh_template()
  if config.remote_login then
    return { "ssh", "-T", "{addr}", "exec ${SHELL:-/bin/sh} -lc {cmd}" }
  end
  return { "ssh", "-T", "{addr}", "{cmd}" }
end

-- Substitute one template element. `{addr}` is always literal (a hostname/id, or
-- a fragment of one; any later shell crossing is handled by shelljoin). `{cmd}`
-- is the inner command: passed RAW when it IS the whole element (a direct argv
-- slot -- `sh -lc {cmd}` -- nothing re-parses it), shell-ESCAPED when embedded in
-- a larger word (a shell on the far side, e.g. ssh's remote shell, re-parses it).
local function subst(elem, addr, inner)
  if elem == "{cmd}" then return inner end
  elem = elem:gsub("{addr}", function() return addr end)
  elem = elem:gsub("{cmd}", function() return vim.fn.shellescape(inner) end)
  return elem
end

-- Resolve a segment to its (template, addr). A registered transport scheme wins;
-- `ssh@…` is an explicit escape hatch; anything else is a plain ssh destination
-- (so `user@host` and bare `host` stay ssh, with the whole segment as the addr).
local function resolve_hop(seg)
  local scheme, addr = seg:match("^([%w_][%w_%-]*)@(.+)$")
  if scheme then
    local t = config.transports[scheme]
    if t then return t, addr end
    if scheme == "ssh" then return ssh_template(), addr end
  end
  return ssh_template(), seg
end

-- Render an argv as a single shell-command string (each word quoted), so an inner
-- hop's argv can be embedded as the `{cmd}` of the next hop out.
local function shelljoin(argv)
  local parts = {}
  for _, a in ipairs(argv) do parts[#parts + 1] = vim.fn.shellescape(a) end
  return table.concat(parts, " ")
end

-- Build one hop's argv that runs `inner` (a command string) at `addr`. A template
-- is an argv list with {addr}/{cmd}, or a function(addr, inner) -> argv for full
-- control (the escape hatch for anything a template can't express).
local function hop_argv(tmpl, addr, inner)
  if type(tmpl) == "function" then return tmpl(addr, inner) end
  local out = {}
  for _, e in ipairs(tmpl) do out[#out + 1] = subst(e, addr, inner) end
  return out
end

-- Compile a route + command into the argv jobstart runs. Hops read left =
-- outermost, so fold from the RIGHT: the rightmost (innermost) hop runs `cmd`;
-- each hop's argv becomes a shell-quoted command string fed as the next hop OUT's
-- `{cmd}`; the leftmost (outermost) hop yields the final argv.
local function build_argv(target, cmd)
  if target == "" then return { vim.o.shell, vim.o.shellcmdflag, cmd } end
  local segs = vim.split(target, "/", { plain = true })
  local inner = cmd
  for i = #segs, 1, -1 do
    local tmpl, addr = resolve_hop(segs[i])
    local argv = hop_argv(tmpl, addr, inner)
    if i == 1 then return argv end
    inner = shelljoin(argv)
  end
end

-- Run `argv` async, streaming stdout into the fence body LIVE (re-rendering the
-- body as each chunk arrives, so long-running commands update as they go rather
-- than dumping everything at exit). stderr is held and folded in at the end via
-- `transform(out_lines, err_lines, code) -> lines` (the authoritative final
-- render). `line_xform`, if given, post-processes each line of the live preview
-- (e.g. neutralising ``` in agent output). stdin is closed so commands see EOF.
-- `sink(lines, final, code)` decides WHERE the streamed output goes. Default is
-- inline: replace the cell's owned fence body (at `mark`) with `lines`. A buffer
-- sink (see buffer_sink) instead streams into a side buffer and updates a one-line
-- reference. `final`/`code` are set only on the exit call.
-- `retag(code) -> tag|nil` (inline only): on exit, may change the fence's opening
-- delimiter to a different owned tag based on the exit code -- used so a command
-- can DECLARE its output a `menu` (drillable) by its exit status.
-- `on_cell(code, lines) -> cell|nil` (inline only): on exit, may return a line of
-- cell text; if it does, the trigger (the line above the fence) AND the fence are
-- REPLACED by that cell (cursor parked at its end) -- so a command can hand back a
-- ready-to-run cell (e.g. `docker@<id>$$ `) instead of output. Takes precedence
-- over normal painting/retag.
-- `finalize(code)` (inline only): called once on exit, AFTER the body is painted
-- and while the body extmark is still valid, before it's dropped -- so an owner
-- can patch its opener with post-run facts (the typst `#cell` uses it to write
-- the now-known exit code into the opener's `code:` field).
local function run_job(buf, indent, mark, argv, cwd, transform, line_xform, sink, retag, on_cell, finalize)
  local acc, err_data = "", {}
  local n = 1 -- how many body lines we currently occupy (starts: the placeholder)
  -- replace our [row, row+n) body region with `lines`; returns the new n.
  local function inline_paint(lines)
    if not vim.api.nvim_buf_is_valid(buf) then return end
    local pos = vim.api.nvim_buf_get_extmark_by_id(buf, ns, mark, {})
    if not pos[1] then return end -- mark gone (cell re-run / cleared) -> stale
    local out = {}
    for _, l in ipairs(lines) do out[#out + 1] = indent .. l end
    vim.api.nvim_buf_set_lines(buf, pos[1], pos[1] + n, false, out)
    n = #out
  end
  local paint = sink or inline_paint
  local function split_out()
    local lines = vim.split(acc:gsub("\r", ""), "\n", { plain = true })
    while #lines > 0 and lines[#lines] == "" do table.remove(lines) end
    return lines
  end
  local job = vim.fn.jobstart(argv, {
    cwd = cwd,
    stderr_buffered = true,
    on_stdout = function(_, d)
      if not d then return end
      acc = acc .. table.concat(d, "\n")
      vim.schedule(function()
        local lines = split_out()
        if #lines == 0 then return end -- nothing complete yet; keep the placeholder
        if line_xform then for i, l in ipairs(lines) do lines[i] = line_xform(l) end end
        paint(lines)
      end)
    end,
    on_stderr = function(_, d) err_data = d or {} end,
    on_exit = function(_, code)
      vim.schedule(function()
        local final = transform(split_out(), err_data, code)
        -- user cancelled this run (<C-c>): keep whatever it had streamed, append a
        -- `[cancelled]` note, and skip the cell-emit/retag paths (a killed command
        -- hasn't legitimately "declared" anything by its signal-derived exit code).
        if fence.take_cancelled(buf, mark) then
          final[#final + 1] = "[cancelled]"
          paint(final, true, code)
          if finalize and not sink and vim.api.nvim_buf_is_valid(buf) then finalize(code) end
          pcall(vim.api.nvim_buf_del_extmark, buf, ns, mark)
          if inflight[buf] then inflight[buf][mark] = nil end
          return
        end
        -- inline only: a command can EMIT A CELL -- swap its trigger + fence for a
        -- single line of cell text (e.g. a `docker@<id>$$ ` session cell). Takes
        -- precedence over painting; the fence/extmark are removed in the process.
        if on_cell and not sink and vim.api.nvim_buf_is_valid(buf) then
          local cell = on_cell(code, final)
          local pos = cell and vim.api.nvim_buf_get_extmark_by_id(buf, ns, mark, {})
          if pos and pos[1] and pos[1] >= 2 then
            local body, total = pos[1], vim.api.nvim_buf_line_count(buf)
            local trigr = body - 2 -- trigger is the line above the opening fence
            local endr = body      -- scan from the body for the closing ``` (exclusive end)
            for r = body, total - 1 do
              if (vim.api.nvim_buf_get_lines(buf, r, r + 1, false)[1] or ""):match("^%s*```%s*$") then
                endr = r + 1; break
              end
            end
            local newline = indent .. cell
            vim.api.nvim_buf_set_lines(buf, trigr, endr, false, { newline })
            pcall(vim.api.nvim_buf_del_extmark, buf, ns, mark)
            if inflight[buf] then inflight[buf][mark] = nil end
            if vim.api.nvim_get_current_buf() == buf then
              pcall(vim.api.nvim_win_set_cursor, 0, { trigr + 1, #newline })
            end
            return
          end
        end
        paint(#final > 0 and final or { "(no output)" }, true, code)
        -- inline only: patch the opener with post-run facts (typst #cell exit code)
        -- while the body extmark still resolves the region.
        if finalize and not sink and vim.api.nvim_buf_is_valid(buf) then finalize(code) end
        -- inline only: let the command re-tag its own fence by exit code (e.g.
        -- exit 150 -> `menu`). The body extmark still resolves the body top, so
        -- the opening delimiter is the line just above it.
        if retag and not sink and vim.api.nvim_buf_is_valid(buf) then
          local newtag = retag(code)
          local pos = newtag and vim.api.nvim_buf_get_extmark_by_id(buf, ns, mark, {})
          if pos and pos[1] and pos[1] > 0 then
            vim.api.nvim_buf_set_lines(buf, pos[1] - 1, pos[1], false, { indent .. "```" .. newtag })
          end
        end
        pcall(vim.api.nvim_buf_del_extmark, buf, ns, mark)
        if inflight[buf] then inflight[buf][mark] = nil end
      end)
    end,
  })
  if job > 0 then
    inflight[buf][mark] = job
    pcall(vim.fn.chanclose, job, "stdin")
  end
end

-- ───────────────────────── side-buffer output (<C-CR>) ───────────────────────
-- <C-CR> on a cell streams its output into a separate scratch buffer instead of
-- inline, leaving a compact `log` reference fence under the trigger. The buffer
-- name `bsh://out/<doc>/<n>` is written INTO the fence and IS the durable link;
-- `out_bufs` is just a session cache from that name to the live bufnr. The buffer
-- is created only when the cell's fence doesn't already link a live one, so
-- re-running a `tail -f` / dev-server cell reuses its buffer instead of littering.
local out_bufs, out_seq = {}, 0

-- Reuse the buffer the cell already links (via `link`, parsed from its `log`
-- fence) if it's still alive; otherwise mint a fresh `bsh://out/<doc>/<n>`.
local function ensure_out_buffer(link)
  if link and out_bufs[link] and vim.api.nvim_buf_is_valid(out_bufs[link]) then
    return out_bufs[link], link
  end
  out_seq = out_seq + 1
  local doc = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t")
  if doc == "" then doc = "scratch" end
  local name = "bsh://out/" .. doc .. "/" .. out_seq
  local b = vim.api.nvim_create_buf(true, false)
  pcall(vim.api.nvim_buf_set_name, b, name)
  vim.bo[b].buftype = "nofile"
  vim.bo[b].bufhidden = "hide"
  vim.bo[b].swapfile = false
  out_bufs[name] = b
  return b, name
end

-- If the cell at `trow` already owns a `log` fence, return its `bsh://out/…` link.
local function existing_log_link(buf, trow)
  local head = vim.api.nvim_buf_get_lines(buf, trow + 1, trow + 2, false)[1] or ""
  if not head:match("^%s*```log%s*$") then return nil end
  local body = vim.api.nvim_buf_get_lines(buf, trow + 2, trow + 3, false)[1] or ""
  return body:match("(bsh://out/%S+)")
end

-- A sink that streams into `sidebuf` (follow/autoscroll) and keeps the cell's
-- reference line (at `mark`) showing the link + live status.
local function buffer_sink(buf, mark, indent, sidebuf, link)
  return function(lines, final, code)
    if vim.api.nvim_buf_is_valid(sidebuf) then
      vim.api.nvim_buf_set_lines(sidebuf, 0, -1, false, lines)
      for _, w in ipairs(vim.fn.win_findbuf(sidebuf)) do -- follow to bottom
        pcall(vim.api.nvim_win_set_cursor, w, { math.max(1, #lines), 0 })
      end
    end
    local status = link .. "  ·  " .. #lines .. (#lines == 1 and " line" or " lines")
        .. "  ·  " .. (final and ("exit " .. (code or 0)) or "running…") .. "  ·  <CR> open"
    if vim.api.nvim_buf_is_valid(buf) then
      local pos = vim.api.nvim_buf_get_extmark_by_id(buf, ns, mark, {})
      if pos[1] then
        vim.api.nvim_buf_set_lines(buf, pos[1], pos[1] + 1, false, { indent .. status })
      end
    end
  end
end

-- Set up a side-buffer run for the cell at `trow`: reuse/mint the buffer (via
-- `link`, if the cell already owns a `log` fence), clear it, stage the `log`
-- reference fence, and return (mark, sink). Every run path's <C-CR> branch uses
-- this, so the inline-vs-buffer fork stays a one-liner in each.
local function begin_buffer_run(buf, trow, indent, link)
  local sidebuf, name = ensure_out_buffer(link)
  vim.api.nvim_buf_set_lines(sidebuf, 0, -1, false, {}) -- clear for a fresh stream
  local mark = stage_fence(buf, trow, indent, "log", name .. "  ·  running…  ·  <CR> open")
  return mark, buffer_sink(buf, mark, indent, sidebuf, name)
end

-- Open a cell's output buffer (from its `bsh://out/…` link) in a split.
local function open_out_buffer(name)
  local b = out_bufs[name]
  if not (b and vim.api.nvim_buf_is_valid(b)) then
    vim.notify("bsh: output buffer " .. name .. " is closed (ephemeral, gone)",
      vim.log.levels.WARN)
    return
  end
  vim.cmd("split")
  vim.api.nvim_win_set_buf(0, b)
  vim.cmd("normal! G")
end

-- Shell-style result: stdout, then any stderr, then a non-zero exit note.
local function shell_transform(out_data, err_data, code)
  local lines = {}
  while #out_data > 0 and out_data[#out_data] == "" do table.remove(out_data) end
  vim.list_extend(lines, out_data)
  local errs = {}
  for _, l in ipairs(err_data) do if l ~= "" then errs[#errs + 1] = l end end
  if #errs > 0 then
    if #lines > 0 then lines[#lines + 1] = "" end
    lines[#lines + 1] = "[stderr]"
    vim.list_extend(lines, errs)
  end
  if code ~= 0 then lines[#lines + 1] = "[exit " .. code .. "]" end
  return lines
end

-- The document's directory (local cells run there); remote cells ignore cwd.
local function doc_cwd(buf)
  local cwd = vim.fn.expand("#" .. buf .. ":p:h")
  if cwd == "" or vim.fn.isdirectory(cwd) == 0 then cwd = vim.fn.getcwd() end
  return cwd
end

-- `$ <cmd>` (or `<user@host>$ <cmd>`) : run a shell command. Output goes inline
-- in an `out` fence; with `to_buf` (<C-CR>), into a side buffer with a `log`
-- reference fence. A cell that already owns a `log` fence stays routed there even
-- on a plain <CR> (sticky), reusing that same buffer.
-- `opts` (optional): { transform, retag, on_cell } -- the namespace path passes
-- these so a command's exit code can declare its output a `menu`, or EMIT a cell
-- that replaces the trigger (see bsh.namespace).
local function run_shell(buf, trow, indent, target, cmd, to_buf, opts)
  opts = opts or {}
  local transform = opts.transform or shell_transform
  local link = existing_log_link(buf, trow)
  if link then to_buf = true end -- sticky: keep an opted-in cell on its buffer
  local remote = target ~= ""
  local cwd = remote and nil or doc_cwd(buf)
  if to_buf then
    local mark, sink = begin_buffer_run(buf, trow, indent, link)
    run_job(buf, indent, mark, build_argv(target, cmd), cwd, transform, nil, sink)
    return
  end
  -- `.bsh.typ`: the owned result is a `#cell(...)` element (structured -> a card),
  -- not an ```out fence. Stage it from the command + run-context, and patch the
  -- now-known exit code into the opener on finish (finalize).
  if vim.b[buf].bsh_typst then
    local meta = {
      cmd = cmd,
      host = remote and target or nil,
      cwd = remote and nil or vim.fn.fnamemodify(doc_cwd(buf), ":~"),
    }
    local mark = fence.stage_cell(buf, trow, indent, meta,
      remote and ("...running on " .. target .. "...") or "...running...")
    run_job(buf, indent, mark, build_argv(target, cmd), cwd, transform, nil, nil, nil, nil,
      function(code) fence.cell_recode(buf, mark, code) end)
    return
  end
  local mark = stage_fence(buf, trow, indent, "out",
    remote and ("...running on " .. target .. "...") or "...running...")
  run_job(buf, indent, mark, build_argv(target, cmd), cwd, transform, nil, nil, opts.retag, opts.on_cell)
end

-- A one-shot (`$`) run of an explicit argv (used for non-shell one-shots like
-- `python $`; shell one-shots go through run_shell/build_argv). Inline by default;
-- `to_buf` (<C-CR>, or sticky) routes it to a side buffer like everything else.
local function run_oneshot(buf, trow, indent, argv, to_buf)
  local link = existing_log_link(buf, trow)
  if link then to_buf = true end
  if to_buf then
    local mark, sink = begin_buffer_run(buf, trow, indent, link)
    run_job(buf, indent, mark, argv, doc_cwd(buf), shell_transform, nil, sink)
    return
  end
  local mark = stage_fence(buf, trow, indent, "out", "...running...")
  run_job(buf, indent, mark, argv, doc_cwd(buf), shell_transform)
end

-- Cancel the one-shot (`$`/`%`) job under the cursor. Each candidate is an
-- in-flight body extmark; the cell it belongs to spans from its trigger (two
-- lines above the body) down to its closing ```. With several jobs inflight, only the
-- one whose region contains `row`. Sets the cancelled flag (so on_exit renders
-- `[cancelled]`) and stops the job; its on_exit does the painting/cleanup.
-- Returns true if a job was cancelled. Session jobs aren't tracked here (they live
-- in bsh.session); the dispatcher tries those separately.
function M.cancel_at(buf, row)
  local jobs = inflight[buf]

  if not jobs then return false end

  local total = vim.api.nvim_buf_line_count(buf)
  local cands = {}
  for mark, jb in pairs(jobs) do
    local pos = vim.api.nvim_buf_get_extmark_by_id(buf, ns, mark, {})
    if pos[1] then
      local body, close = pos[1], pos[1]
      for r = body, total - 1 do
        if (vim.api.nvim_buf_get_lines(buf, r, r + 1, false)[1] or ""):match("^%s*```%s*$") then
          close = r; break
        end
      end
      cands[#cands + 1] = { mark = mark, job = jb, top = math.max(0, body - 2), close = close }
    end
  end
  if #cands == 0 then return false end
  local target

  -- find the actual target falls within the row range we issued our cancel call in
  for _, c in ipairs(cands) do
    if row >= c.top and row <= c.close then
      target = c; break
    end
  end

  if not target then return false end

  fence.set_cancelled(buf, target.mark)
  pcall(vim.fn.jobstop, target.job)
  return true
end

M.build_argv = build_argv
M.run_job = run_job
M.shell_transform = shell_transform
M.doc_cwd = doc_cwd
M.existing_log_link = existing_log_link
M.begin_buffer_run = begin_buffer_run
M.open_out_buffer = open_out_buffer
M.run_shell = run_shell
M.run_oneshot = run_oneshot
return M
