-- bsh: a "live document" buffer in the spirit of xiki/notebooks.
--
-- A *cell* is a trigger line followed by a result fence that THIS MODULE owns
-- and rewrites. Pressing <CR> on the trigger runs it and replaces the fence's
-- body in place -- so re-running is idempotent (edit the line, <CR> again, the
-- old output is replaced, never duplicated). The fence delimiters are the
-- result's start/end markers, so there is no separate END syntax to invent, and
-- the whole thing survives :w / reload and folds like normal markdown.
--
-- Step 1 implements only the `$` shell cell:
--
--     $ ls -la
--     ```out
--     total 48
--     drwxr-xr-x  5 mktips ...
--     ```
--
-- Future cell kinds (`:` paths, `https://` summaries, `>` agentic llm) plug
-- into the same dispatcher + find-or-replace-fence machinery.

local M = {}

-- Remote (`user@host$ cmd`) cells run in a login shell so the remote profile
-- and bashrc load (PATH, pkg, env). Set false for a bare, faster `ssh host cmd`
-- when the remote already has the env you need or you want zero startup files.
M.remote_login = true

-- `> instruction` agent cells call `llm -t <template>`; the default `web`
-- template carries tools (search/fetch), so a `>` after a link can summarise it.
-- Point this at a more agentic template if you make one.
M.agent_template = "web"

-- interpreter used for `python` cells (one-shot `python $` and session `python $$`).
M.python = "python3"

-- language a `foo.bar!` define-in-place scaffolds a NEW leaf in: "sh" (a plain
-- shell command, lowest friction) or "python" (the dual-purpose command/`llm`
-- tool skeleton). Cosmetic extension only; dispatch stays shebang-driven.
M.scaffold_lang = "sh"

-- Yes/no gate before `foo.bar!` creates a NEW file (so a stray `word!` line can't
-- silently scaffold). Overridable for customisation / tests; return true = go.
M.confirm = function(prompt)
  return vim.fn.confirm(prompt, "&Yes\n&No", 2) == 1
end

local ns = vim.api.nvim_create_namespace("bsh")

-- in-flight shell jobs, keyed by buffer then by the body extmark id, so a cell
-- re-run can cancel its own still-running job before staging a fresh fence.
local inflight = {}

-- Locate (or plan the insertion of) the result fence that belongs to the
-- trigger on 0-indexed row `trow`. The owned fence must begin on the very next
-- line as `<indent>```<tag>` (tag is "out" for shell, "dir" for listings).
-- Returns the inclusive 0-indexed row range [start, stop) currently occupied by
-- a fence (empty range = none yet, insert a fresh one right after the trigger).
local OWNED_TAGS = { out = true, dir = true, tree = true, agent = true, log = true }
local function fence_range(buf, trow, indent, tag)
  local open = trow + 1
  local total = vim.api.nvim_buf_line_count(buf)
  if open >= total then return open, open end
  local l = vim.api.nvim_buf_get_lines(buf, open, open + 1, false)[1] or ""
  -- Match ANY owned tag, not just `tag`: when a trigger's output changes kind
  -- (e.g. an `out` cell edited into a `dir` listing) the existing fence must be
  -- recognised as ours and REPLACED, not left orphaned above the new one.
  local existing = l:match("^%s*```(%S+)%s*$")
  if not (existing and OWNED_TAGS[existing]) then return open, open end
  -- found an owned opening fence; scan for its closing ```
  for r = open + 1, total - 1 do
    local ll = vim.api.nvim_buf_get_lines(buf, r, r + 1, false)[1] or ""
    if ll:match("^%s*```%s*$") then return open, r + 1 end
  end
  -- unterminated fence: treat just the opening line as the region
  return open, open + 1
end

-- Cancel any still-running job whose body anchor lives in rows [start, stop)
-- (its on_exit becomes a no-op once its mark is gone) and drop those marks.
local function clear_inflight(buf, start, stop)
  inflight[buf] = inflight[buf] or {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, { start, 0 }, { stop, -1 }, {})) do
    local id, job = m[1], inflight[buf][m[1]]
    if job then pcall(vim.fn.jobstop, job); inflight[buf][id] = nil end
    pcall(vim.api.nvim_buf_del_extmark, buf, ns, id)
  end
end

-- Replace rows [start, stop) with { open, placeholder, close } and return an
-- extmark anchoring the START of the body, so the async result lands exactly
-- there even if the buffer shifts meanwhile. LEFT gravity (right_gravity=false)
-- so that when streaming repaints the body via set_lines over [mark, mark+n),
-- the mark stays pinned at the body's top instead of being pushed below it.
local function stage_block(buf, start, stop, open, placeholder, close)
  clear_inflight(buf, start, stop)
  vim.api.nvim_buf_set_lines(buf, start, stop, false, { open, placeholder, close })
  return vim.api.nvim_buf_set_extmark(buf, ns, start + 1, 0, { right_gravity = false })
end

-- Drop a fresh `<tag>` fence with a placeholder body in place of any existing one.
local function stage_fence(buf, trow, indent, tag, placeholder)
  local start, stop = fence_range(buf, trow, indent, tag)
  return stage_block(buf, start, stop,
    indent .. "```" .. tag, indent .. placeholder, indent .. "```")
end

-- Replace the placeholder body line (located via its extmark) with `lines`,
-- each indented to match the trigger. The closing fence below it is untouched.
local function fill_fence(buf, mark, indent, lines)
  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(buf) then return end
    local pos = vim.api.nvim_buf_get_extmark_by_id(buf, ns, mark, {})
    if not pos[1] then return end
    local row = pos[1]
    local out = {}
    for _, l in ipairs(#lines > 0 and lines or { "(no output)" }) do
      out[#out + 1] = indent .. l
    end
    vim.api.nvim_buf_set_lines(buf, row, row + 1, false, out)
    pcall(vim.api.nvim_buf_del_extmark, buf, ns, mark)
    if inflight[buf] then inflight[buf][mark] = nil end
  end)
end

-- Build the argv to run a command string on `target`. Local (target == "")
-- goes through the user's shell so pipes/globs/redirs work. Remote runs over ssh
-- in a *login* shell (so the remote profile/bashrc -- and thus PATH, pkg, env --
-- load; a bare `ssh host cmd` sources none of that).
--   -T: no pseudo-tty (we capture non-interactively); stdin is closed by the
--   caller, so auth must be non-interactive (ssh-agent/keys).
--   ssh re-joins its trailing args with spaces and the REMOTE shell re-parses
--   the result, so `cmd` must be shell-quoted or it would word-split remotely.
local function build_argv(target, cmd)
  if target == "" then
    return { vim.o.shell, vim.o.shellcmdflag, cmd }
  elseif M.remote_login then
    return { "ssh", "-T", target, "exec ${SHELL:-/bin/sh} -lc " .. vim.fn.shellescape(cmd) }
  else
    return { "ssh", "-T", target, cmd }
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
local function run_job(buf, indent, mark, argv, cwd, transform, line_xform, sink)
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
        paint(#final > 0 and final or { "(no output)" }, true, code)
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

-- The namespace root ($BSH_HOME, default ~/pockt/bsh). Returns "" when it
-- doesn't exist, so namespace cells simply don't fire if it isn't set up (prose
-- stays prose). The directory tree under it IS the namespace, 1:1, no registry.
local function ns_home()
  local h = vim.env.BSH_HOME
  if not h or h == "" then h = "~/pockt/bsh" end
  h = vim.fn.expand(h)
  return vim.fn.isdirectory(h) == 1 and h or ""
end

-- `$ <cmd>` (or `<user@host>$ <cmd>`) : run a shell command. Output goes inline
-- in an `out` fence; with `to_buf` (<C-CR>), into a side buffer with a `log`
-- reference fence. A cell that already owns a `log` fence stays routed there even
-- on a plain <CR> (sticky), reusing that same buffer.
local function run_shell(buf, trow, indent, target, cmd, to_buf)
  local link = existing_log_link(buf, trow)
  if link then to_buf = true end -- sticky: keep an opted-in cell on its buffer
  local remote = target ~= ""
  local cwd = remote and nil or doc_cwd(buf)
  if to_buf then
    local sidebuf, name = ensure_out_buffer(link)
    vim.api.nvim_buf_set_lines(sidebuf, 0, -1, false, {}) -- clear for a fresh stream
    local mark = stage_fence(buf, trow, indent, "log", name .. "  ·  starting…  ·  <CR> open")
    run_job(buf, indent, mark, build_argv(target, cmd), cwd, shell_transform, nil,
      buffer_sink(buf, mark, indent, sidebuf, name))
    return
  end
  local mark = stage_fence(buf, trow, indent, "out",
    remote and ("...running on " .. target .. "...") or "...running...")
  run_job(buf, indent, mark, build_argv(target, cmd), cwd, shell_transform)
end

-- ──────────────────────── persistent language sessions ───────────────────────
-- A `$$` cell runs in ONE long-lived process that belongs to this buffer, so
-- state (exported vars, `cd`, Python imports/variables, an activated venv) all
-- persist from one cell to the next. Plain `$` stays a fresh one-shot -- use it
-- when you want isolation, `$$` to build up state.
--
-- Each session is fed work on stdin and frames the result with a random sentinel
-- line `__BSH_<token>__:<status>`; we stream stdout, and when the sentinel
-- appears that unit is done, so we slice the output and drop it in the cell's
-- `out` fence. Units are serialised through a small per-(buffer,language) queue.
-- A `spec` per language plugs in how to start the process and how to submit code
-- and emit the sentinel; the streaming/parsing below is shared.
--
--   sh:     a login shell (env loads once); submit = command + a `printf` of the
--           sentinel carrying `$?`; `exec 2>&1` folds stderr into the stream.
--   python: a tiny driver (below) that reads LENGTH-PREFIXED code chunks and
--           `exec`s each into a persistent globals dict -- length-framing makes
--           multiline/indentation a non-issue (one atomic exec), and the driver
--           prints the sentinel itself. stderr is aliased to stdout for order.
local sessions = {} -- [buf] = { [lang] = { job, spec, token, acc, busy, current, queue } }

-- Python driver run as `python -u -c <this>`; @TOKEN@ is substituted per session.
local DRIVER_PY = [[
import sys, traceback
_in = sys.stdin.buffer
sys.stderr = sys.stdout              # keep tracebacks/prints in stream order
G = {"__name__": "__main__"}
while True:
    h = _in.readline()
    if not h:
        break
    try:
        n = int(h)
    except ValueError:
        continue
    src = _in.read(n).decode("utf-8", "replace")
    st = 0
    try:
        exec(compile(src, "<cell>", "exec"), G)
    except SystemExit:
        pass
    except BaseException as e:
        tb = e.__traceback__.tb_next   # drop our own exec() frame from the trace
        traceback.print_exception(type(e), e, tb)
        st = 1
    sys.stdout.write("\n__BSH_@TOKEN@__:%d\n" % st)
    sys.stdout.flush()
]]

local SPECS = {
  sh = {
    -- local: a login shell (env loads once). remote (`user@host$$`): the SAME
    -- shell over ssh, so a persistent remote session works exactly like a local
    -- one (env loads via the remote login shell). -T = no pty; cmds on stdin.
    argv = function(_, target)
      if target == "" then return { vim.o.shell, "-l" } end
      return { "ssh", "-T", target, "exec ${SHELL:-/bin/sh} -l" }
    end,
    init = function(s) vim.fn.chansend(s.job, "exec 2>&1\n") end,
    send = function(s, code)
      vim.fn.chansend(s.job, code ..
        "\nprintf '\\n__BSH_" .. s.token .. "__:%d\\n' \"$?\"\n")
    end,
  },
  python = {
    argv = function(token, _) return { M.python, "-u", "-c", (DRIVER_PY:gsub("@TOKEN@", token)) } end,
    init = function() end,
    send = function(s, code) -- length-prefixed chunk: header line + exact bytes
      vim.fn.chansend(s.job, tostring(#code) .. "\n" .. code)
    end,
  },
}

-- A session is keyed per buffer by language AND target, so a local bash session
-- and a `user@host` remote one (or two different hosts) coexist independently.
local function skey(lang, target)
  return target ~= "" and (lang .. "@" .. target) or lang
end

local function sess_pump(buf, key)
  local s = sessions[buf] and sessions[buf][key]
  if not s or s.busy then return end
  local item = table.remove(s.queue, 1)
  if not item then return end
  s.busy, s.current = true, item
  s.spec.send(s, item.cmd)
end

local function sess_start(buf, lang, target)
  local spec = SPECS[lang]
  local key = skey(lang, target)
  local s = { lang = lang, spec = spec, acc = "", busy = false, queue = {},
              token = string.format("%08x", math.random(0, 0xffffffff)) }
  local job = vim.fn.jobstart(spec.argv(s.token, target), {
    cwd = doc_cwd(buf),
    on_stdout = function(_, data)
      if not data then return end
      s.acc = s.acc .. table.concat(data, "\n")
      while true do
        local a, b, rc = s.acc:find("\n__BSH_" .. s.token .. "__:(%d+)\r?\n")
        if not a then break end
        local body = s.acc:sub(1, a - 1) -- everything before the sentinel line
        s.acc = s.acc:sub(b + 1)
        local item = s.current
        s.busy, s.current = false, nil
        if item then
          local lines = vim.split(body:gsub("\r", ""), "\n", { plain = true })
          while #lines > 0 and lines[#lines] == "" do table.remove(lines) end
          if tonumber(rc) ~= 0 then lines[#lines + 1] = "[exit " .. rc .. "]" end
          fill_fence(buf, item.mark, item.indent, lines)
        end
        sess_pump(buf, key) -- drain anything queued behind it
      end
    end,
    on_exit = function() if sessions[buf] then sessions[buf][key] = nil end end,
  })
  if job <= 0 then return nil end
  s.job = job
  spec.init(s)
  sessions[buf] = sessions[buf] or {}
  sessions[buf][key] = s
  return s
end

-- Queue `cmd` on this buffer's `lang`@`target` session, staging an `out` fence.
local function run_session(buf, lang, target, trow, indent, cmd)
  local key = skey(lang, target)
  if not (sessions[buf] and sessions[buf][key]) then
    if not sess_start(buf, lang, target) then
      vim.notify("bsh: could not start " .. lang .. " session", vim.log.levels.ERROR)
      return
    end
  end
  local mark = stage_fence(buf, trow, indent, "out", "...running (session)...")
  table.insert(sessions[buf][key].queue, { cmd = cmd, mark = mark, indent = indent })
  sess_pump(buf, key)
end

-- A one-shot (`$`) run of an explicit argv into an `out` fence (used for non-shell
-- one-shots like `python $`; shell one-shots go through run_shell/build_argv).
local function run_oneshot(buf, trow, indent, argv)
  local mark = stage_fence(buf, trow, indent, "out", "...running...")
  run_job(buf, indent, mark, argv, doc_cwd(buf), shell_transform)
end

-- Stop all of a buffer's session processes (called when the buffer goes away).
function M.stop_session(buf)
  if sessions[buf] then
    for _, s in pairs(sessions[buf]) do
      if s.job then pcall(vim.fn.jobstop, s.job) end
    end
    sessions[buf] = nil
  end
end

-- `: path [-T] [-H]` : peel any trailing recognised flags off the trigger
-- remainder, leaving the path. -T = tree view, -H = include hidden (dotfiles).
-- Empty path means the document/login dir.
local function parse_list_args(rest)
  local flags = { tree = false, hidden = false }
  local path = rest
  while true do
    local f = path:match("%s(%-%a)%s*$")
    if f == "-T" then flags.tree = true
    elseif f == "-H" then flags.hidden = true
    else break end -- no flag, or an unknown one we leave in the path
    path = path:gsub("%s%-%a%s*$", "", 1)
  end
  path = (path:gsub("^%s+", "")):gsub("%s+$", "")
  if path == "" then path = "." end
  return path, flags
end

-- Quote a path for the shell while keeping a leading ~ / ~user prefix expandable.
-- Tilde expansion needs the slash right after ~ to be UNQUOTED (it ends the
-- tilde-prefix), so keep `~prefix/` verbatim and shellescape only the rest.
local function qpath(path)
  local pre, rest = path:match("^(~[^/]*/)(.*)$")
  if pre then return pre .. (rest == "" and "" or vim.fn.shellescape(rest)) end
  if path:match("^~[^/]*$") then return path end -- bare ~ or ~user
  return vim.fn.shellescape(path)
end

local run_goto -- forward decl (run_list dispatches to it; it lists the result)

-- `: <path>` (or `<user@host>: <path>`) : list a directory into a navigable
-- `dir` fence; with `-T`, a navigable `tree` fence (paths reconstructed from the
-- tree's indentation on <CR>). Dotfiles hidden unless `-H`. `ls -1p` / `tree -F`
-- are portable (BSD+GNU) and mark directories with a trailing /.
--
-- Special: `: goto <query>` fuzzy-resolves <query> to a path via the user's own
-- `here` helper (fd|fzf --filter, works locally or on the remote target) and
-- lists THAT -- so you can jump by a remembered fragment of a folder's name.
local function run_list(buf, trow, indent, target, rest)
  local path, flags = parse_list_args(rest)
  local query = path:match("^goto%s+(.+)$")
  if query then return run_goto(buf, trow, indent, target, query, flags) end
  local remote = target ~= ""
  local cwd = remote and nil or doc_cwd(buf)

  if flags.tree then
    local mark = stage_fence(buf, trow, indent, "tree", "...listing...")
    -- tree -F marks dirs with /, needed to resolve clicks; -a shows hidden.
    local cmd = "tree -F " .. (flags.hidden and "-a " or "") .. "-- " .. qpath(path)
    run_job(buf, indent, mark, build_argv(target, cmd), cwd, shell_transform)
    return
  end

  local ls = flags.hidden and "ls -1Ap -- " or "ls -1p -- "
  local mark = stage_fence(buf, trow, indent, "dir",
    remote and ("...listing " .. target .. "...") or "...listing...")
  run_job(buf, indent, mark, build_argv(target, ls .. qpath(path)), cwd,
    function(out, err, code)
      if code ~= 0 then return shell_transform(out, err, code) end
      -- group dirs first (trailing /), then files; prepend ../ for walking up
      local dirs, files = {}, {}
      for _, l in ipairs(out) do
        if l ~= "" then
          if l:sub(-1) == "/" then dirs[#dirs + 1] = l else files[#files + 1] = l end
        end
      end
      local lines = { "../" }
      vim.list_extend(lines, dirs)
      vim.list_extend(lines, files)
      return lines
    end)
end

-- `: goto <query>` : resolve <query> with `here` (prints the best fuzzy path),
-- then rewrite the trigger to `: <resolved-path>` and list it in place -- the
-- same oil-style rewrite as drilling into a folder, just with a fuzzy entry
-- point. Works on the remote target too (its own `here`/$HOME).
function run_goto(buf, trow, indent, target, query, flags)
  local mark = stage_fence(buf, trow, indent, flags.tree and "tree" or "dir", "...resolving...")
  local out = {}
  local job = vim.fn.jobstart(build_argv(target, "here " .. vim.fn.shellescape(query)), {
    cwd = target == "" and doc_cwd(buf) or nil,
    stdout_buffered = true,
    on_stdout = function(_, d) out = d or {} end,
    on_exit = function()
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(buf) then return end
        local pos = vim.api.nvim_buf_get_extmark_by_id(buf, ns, mark, {})
        if not pos[1] then return end
        local path
        for _, l in ipairs(out) do if l ~= "" then path = l; break end end
        if not path then -- no match: leave a note where the listing would be
          vim.api.nvim_buf_set_lines(buf, pos[1], pos[1] + 1, false,
            { indent .. "(goto: no match for '" .. query .. "')" })
          pcall(vim.api.nvim_buf_del_extmark, buf, ns, mark)
          if inflight[buf] then inflight[buf][mark] = nil end
          return
        end
        local suffix = (flags.tree and " -T" or "") .. (flags.hidden and " -H" or "")
        -- the body mark sits two rows below the trigger (trigger / ```open / body)
        local trig_row = pos[1] - 2
        vim.api.nvim_buf_set_lines(buf, trig_row, trig_row + 1, false,
          { indent .. (target ~= "" and (target .. ": ") or ": ") .. path .. suffix })
        run_list(buf, trig_row, indent, target, path .. suffix) -- re-stages the fence
      end)
    end,
  })
  if job > 0 then inflight[buf][mark] = job; pcall(vim.fn.chanclose, job, "stdin") end
end

-- Join a listing's base path with a clicked entry; `..` walks up one segment
-- (pure string op, so it works for remote paths too).
local function join_path(base, name)
  if name == ".." then return vim.fn.fnamemodify((base:gsub("/+$", "")), ":h") end
  base = (base:gsub("/+$", ""))
  if base == "" then base = "." end
  return base .. "/" .. name
end

-- Open a file entry: local via :edit; remote via netrw scp:// (best effort,
-- needs netrw enabled). `~/x` -> home-relative URL, `/x` -> // absolute URL.
local function open_entry(target, path)
  if target == "" then
    vim.cmd("edit " .. vim.fn.fnameescape(vim.fn.expand(path)))
    return
  end
  -- netrw shells out to `scp` for scp:// reads; without this it echoes the
  -- command and leaves a hit-ENTER prompt, so opening a remote file took two
  -- <CR>s. Silent transfers skip that prompt -> one <CR>, like local files.
  vim.g.netrw_silent = 1
  local rel = path:match("^~/(.*)$")
  local url = "scp://" .. target .. "/" .. (rel or path)
  vim.cmd("edit " .. vim.fn.fnameescape(url))
end

-- If `row` sits on an entry line inside a navigable fence, return its opening
-- fence row (0-indexed) and tag ("dir" | "tree"); otherwise nil.
local function fence_open(buf, row)
  local cur = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
  if cur:match("^%s*```") then return nil end -- on a fence line, not an entry
  for r = row - 1, 0, -1 do
    local s = vim.api.nvim_buf_get_lines(buf, r, r + 1, false)[1] or ""
    local tag = s:match("^%s*```(%S+)%s*$")
    if tag then
      if tag == "dir" or tag == "tree" then return r, tag end
      return nil -- some other fence (e.g. out) -> not navigable
    end
    if s:match("^%s*```%s*$") then return nil end -- closer above -> outside
  end
  return nil
end

-- Parse one `tree -F` body line into (depth, name). The connector `├── `/`└── `
-- (and the `│   `/`    ` indent groups) are multibyte, so match the literal
-- connector and measure depth by display columns (each level = 4 columns).
local function tree_entry(line)
  for _, conn in ipairs({ "├── ", "└── " }) do
    local i = line:find(conn, 1, true)
    if i then
      local depth = math.floor(vim.fn.strdisplaywidth(line:sub(1, i - 1)) / 4) + 1
      return depth, line:sub(i + #conn)
    end
  end
  return nil -- root line / summary / blank: not an entry
end

-- Reconstruct the path of the tree entry at `row` by walking up to collect one
-- ancestor name per shallower depth, then joining onto the listing's base path.
-- `lo` is the first body row of the fence. Returns full_path, is_dir (or nil).
local function tree_path(buf, lo, row, base)
  local function nm(r) return vim.api.nvim_buf_get_lines(buf, r, r + 1, false)[1] or "" end
  local depth, name = tree_entry(nm(row))
  if not depth then return nil end
  local parts, need = { [depth] = name }, depth - 1
  for r = row - 1, lo, -1 do
    local d, n = tree_entry(nm(r))
    if d == need then parts[need] = n; need = need - 1; if need == 0 then break end end
  end
  -- strip tree -F type markers (/ * = @ |) to recover bare names
  local rel = {}
  for d = 1, depth do rel[d] = (parts[d] or ""):gsub("[/*=@|]$", "") end
  return join_path(base, table.concat(rel, "/")), name:sub(-1) == "/"
end

-- Open a URL in the browser: prefer $BROWSER (the user sets it per-OS), else
-- fall back to vim.ui.open (xdg-open/open/...). Detached so it outlives nvim.
local function open_url(url)
  local browser = vim.env.BROWSER
  if browser and browser ~= "" then
    vim.fn.jobstart({ browser, url }, { detach = true })
  elseif vim.ui.open then
    vim.ui.open(url)
  else
    vim.fn.jobstart({ "xdg-open", url }, { detach = true })
  end
end

-- Agent output goes in an owned `agent` fence, just like every other cell. The
-- catch a ``` fence has -- the model emitting its own ``` and closing ours early
-- -- is handled by `agent_transform`: it runs the normal shell transform, then
-- swaps every literal ``` run for a backtick LOOK-ALIKE (U+02CB MODIFIER LETTER
-- GRAVE ACCENT, ˋˋˋ) so the model's code blocks still read as code blocks but
-- can never terminate our real fence. Single/double inline backticks are left
-- alone.
local function agent_sanitize(l) return (l:gsub("```", "ˋˋˋ")) end -- also the live line_xform
local function agent_transform(out_data, err_data, code)
  local lines = shell_transform(out_data, err_data, code)
  for i, l in ipairs(lines) do lines[i] = agent_sanitize(l) end
  return lines
end

-- Identify the cell whose bottom is at/above row `from` (skipping blanks) and
-- return its context text plus the row of its top line (so a caller can keep
-- walking up). Recognises: a fenced block (its trigger + body), an agent region
-- (its `>` line + body), a bare URL, or a bare trigger with no result yet.
-- Returns nil on prose / nothing (which stops the walk).
local function cell_above(buf, from)
  local function gl(r) return vim.api.nvim_buf_get_lines(buf, r, r + 1, false)[1] or "" end
  local function looks_trigger(s)
    return s:match("^%S-%$%s") or s:match("^%S-:%s") or s:match("^https?://") or s:match("^>+%s")
  end
  local r = from
  while r >= 0 and gl(r):match("^%s*$") do r = r - 1 end
  if r < 0 then return nil end
  local f = gl(r)

  if f:match("^%s*```%s*$") then -- closing fence of an out/dir/tree block
    local openr
    for rr = r - 1, 0, -1 do
      if gl(rr):match("^%s*```%S") then openr = rr; break end
      if gl(rr):match("^%s*```%s*$") then break end
    end
    if not openr then return nil end
    local parts, top = {}, openr
    local trig = gl(openr - 1):gsub("^%s+", "")
    if looks_trigger(trig) then parts[#parts + 1] = trig; top = openr - 1 end
    vim.list_extend(parts, vim.api.nvim_buf_get_lines(buf, openr + 1, r, false))
    return table.concat(parts, "\n"), top
  end

  if looks_trigger(f:gsub("^%s+", "")) then return (f:gsub("^%s+", "")), r end
  return nil -- prose -> stop
end

-- Gather up to `n` preceding cells as context, in document order (oldest first).
local function gather_context(buf, row, n)
  if n <= 0 then return nil end
  local blocks, from = {}, row - 1
  while #blocks < n do
    local text, top = cell_above(buf, from)
    if not text then break end
    blocks[#blocks + 1] = text
    from = top - 1
  end
  if #blocks == 0 then return nil end
  local ordered = {}
  for i = #blocks, 1, -1 do ordered[#ordered + 1] = blocks[i] end
  return table.concat(ordered, "\n\n")
end

-- `> instruction` : agentic llm call into a comment-delimited region. The number
-- of leading `>` beyond the first picks how many preceding cells to include:
-- `>` = none, `>>` = 1, `>>>` = 2, …
local function run_agent(buf, trow, indent, instruction, ncontext)
  local context = gather_context(buf, trow, ncontext)
  local prompt = instruction
  if context and context ~= "" then
    prompt = prompt .. "\n\n--- preceding cells (context) ---\n" .. context
  end
  local mark = stage_fence(buf, trow, indent, "agent", "...thinking...")
  run_job(buf, indent, mark,
    { "llm", "-t", M.agent_template, "--chain-limit", "15", prompt },
    doc_cwd(buf), agent_transform, agent_sanitize) -- sanitize the live preview too
end

-- Parse a fence info-string into (lang, target, session) or nil if it's not a
-- runnable cell. The run marker is a SUFFIX (`$` once / `$$` session) so the
-- language word stays first and the block still syntax-highlights:
--   $  $$  user@host$            -> bash (lang "sh"), no language word
--   python $   py $$   ruby $$   -> a language word, then optional target + marker
-- No trailing marker (a plain ```python doc block, or ```out) -> nil (inert).
local LANG_ALIAS = { sh = "sh", bash = "sh", shell = "sh", py = "python", python = "python" }
local function parse_runmarker(info)
  local word, rest = info:match("^(%a[%w_]*)%s+(.+)$")
  if word then -- language-prefixed form
    local lang = LANG_ALIAS[word]
    if not lang then return nil end
    local tgt, dbl = rest:match("^(%S-)%$(%$?)$")
    if tgt then return lang, tgt, dbl == "$" end
    return nil
  end
  local tgt, dbl = info:match("^(%S-)%$(%$?)$") -- bare bash form
  if tgt then return "sh", tgt, dbl == "$" end
  return nil
end

-- A MULTILINE input cell is a fenced code block whose info-string parses as a run
-- marker (see parse_runmarker). If the cursor sits anywhere inside such a block,
-- return its open/close rows, indent, language, remote target, session flag, and
-- the joined body; else nil.
local function input_fence_at(buf, row)
  local total = vim.api.nvim_buf_line_count(buf)
  local function gl(r) return vim.api.nvim_buf_get_lines(buf, r, r + 1, false)[1] or "" end
  -- find the opening fence at/above the cursor; bail if we hit a bare ``` first
  -- (that means we're below a closed block, not inside an open one)
  local openr
  for r = row, 0, -1 do
    local l = gl(r)
    if l:match("^%s*```%s*$") then return nil end
    if l:match("^%s*```%S") then openr = r; break end
  end
  if not openr then return nil end
  local lang, target, session = parse_runmarker(vim.trim(gl(openr):match("^%s*```(.*)$") or ""))
  if not lang then return nil end -- e.g. ```out / ```python (no marker) -> inert
  local closer
  for r = openr + 1, total - 1 do
    if gl(r):match("^%s*```%s*$") then closer = r; break end
  end
  if not closer or row > closer then return nil end
  return {
    open = openr, close = closer, indent = gl(openr):match("^(%s*)"),
    lang = lang, target = target, session = session,
    body = table.concat(vim.api.nvim_buf_get_lines(buf, openr + 1, closer, false), "\n"),
  }
end

-- Run a resolved namespace leaf as a SHELL command (not a bare argv), so the
-- cell is a continuation of the shell: `args` is appended raw and the whole line
-- goes through `$`'s one-shot shell, giving redirection, pipes, globs, `$(...)`
-- sub-shells -- everything the outer shell does. The path is quoted; args are not
-- (they ARE shell syntax). Runs in the document's dir, like `$`.
local function run_ns_exec(buf, trow, indent, path, args, to_buf)
  local cmd = vim.fn.shellescape(path)
  if args and args ~= "" then cmd = cmd .. " " .. args end
  run_shell(buf, trow, indent, "", cmd, to_buf)
end

-- A `namespace` cell resolves a dotted name to a path under $BSH_HOME (dots ->
-- slashes): `llm.tools.weather`. Enter dispatches on what's there:
--   * a file is executed by its shebang into an `out` fence (so a dual-purpose
--     `weather.py` runs its `__main__`); the leaf may carry any extension
--     (`...weather` matches `weather` or `weather.<ext>`) since dispatch is
--     shebang- not extension-driven;
--   * a directory with an executable `.enter` runs that;
--   * a directory without one is LISTED -- and the trigger is canonicalised to a
--     TRAILING DOT (`demo` -> `demo.`) so its entries navigate as `demo.<child>`.
-- A trailing dot is also an explicit "peek inside" operator: `demo.greet.` lists
-- the dir even when `demo.greet` (no dot) would have run its `.enter`.
-- `args` (the rest of the line after the dotted name) is passed to an executable
-- leaf/`.enter` as shell args; for a plain directory it's meaningless, so
-- `<dir> <args>` falls through to prose.
-- Returns true if it resolved+handled, false (prose) otherwise.
local function run_namespace(buf, trow, indent, dotted, args, to_buf)
  args = args or ""
  local home = ns_home()
  if home == "" then return false end
  local force_list = dotted:sub(-1) == "."          -- trailing dot = list, not .enter
  local clean = (dotted:gsub("%.+$", ""))           -- strip trailing dot(s)
  if clean == "" then return false end
  local base = home .. "/" .. (clean:gsub("%.", "/"))

  if vim.fn.isdirectory(base) == 1 then
    local enter = base .. "/.enter"
    if not force_list and vim.fn.executable(enter) == 1 then
      run_ns_exec(buf, trow, indent, enter, args, to_buf)
    elseif args ~= "" then
      return false -- `<dir> <args>` with nothing to run -> prose
    else
      -- canonicalise the trigger to `clean.` so the listing's entries resolve as
      -- `clean.<child>` (and re-running this cell is idempotent). List with -H so
      -- the `.enter` (and any other dotfiles in the namespace) are visible.
      vim.api.nvim_buf_set_lines(buf, trow, trow + 1, false, { indent .. clean .. "." })
      run_list(buf, trow, indent, "", base .. " -H") -- navigable listing, hidden shown
    end
    return true
  end

  -- a leaf file: try the exact name, then any single-extension sibling
  local cands = { base }
  for _, g in ipairs(vim.fn.glob(base .. ".*", false, true)) do cands[#cands + 1] = g end
  for _, p in ipairs(cands) do
    if vim.fn.filereadable(p) == 1 then
      if vim.fn.executable(p) == 1 then
        run_ns_exec(buf, trow, indent, p, args, to_buf) -- run by shebang, through the shell
      else
        vim.notify("bsh: " .. p .. " is not executable (chmod +x it)", vim.log.levels.WARN)
      end
      return true
    end
  end
  return false -- nothing under $BSH_HOME -> treat as prose
end

-- The candidate source file for a resolved namespace leaf (exact name first, then
-- a single-extension sibling like `weather.py`); nil if none exists yet.
local function ns_leaf_path(base)
  if vim.fn.filereadable(base) == 1 then return base end
  for _, g in ipairs(vim.fn.glob(base .. ".*", false, true)) do
    if vim.fn.filereadable(g) == 1 then return g end
  end
  return nil
end

-- Starter templates for a freshly scaffolded leaf. `@N@` = the dotted name, `@F@`
-- = the last segment as a valid identifier. Shell is the low-friction default;
-- python is the dual-purpose command/`llm`-tool keystone.
local SCAFFOLD = {
  sh = {
    ext = ".sh",
    body = table.concat({
      "#!/usr/bin/env bash",
      "# bsh command: @N@   (run with: @N@ [args]; args are in \"$@\")",
      "",
      'echo "hello from @N@ $*"',
      "",
    }, "\n"),
  },
  python = {
    ext = ".py",
    body = table.concat({
      "#!/usr/bin/env python3",
      '"""@N@ — a bsh command / llm tool."""',
      "import sys",
      "",
      "",
      "def @F@(text: str = \"\") -> str:",
      '    "TODO: describe what @F@ does."',
      "    return text",
      "",
      "",
      "try:",
      "    import llm",
      "",
      "    @llm.hookimpl",
      "    def register_tools(register):",
      "        register(@F@)",
      "except ImportError:",
      "    pass",
      "",
      "",
      'if __name__ == "__main__":',
      "    print(@F@(\" \".join(sys.argv[1:])))",
      "",
    }, "\n"),
  },
}

-- Write an executable scaffold for `dotted` at `path` and return it. Creates
-- parent dirs; fills the template; sets the exec bit so it's runnable at once.
local function scaffold_leaf(dotted, path)
  local fname = (dotted:gsub(".*%.", "")):gsub("[^%w_]", "_")
  local spec = SCAFFOLD[M.scaffold_lang] or SCAFFOLD.sh
  local body = (spec.body:gsub("@N@", dotted):gsub("@F@", fname))
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile(vim.split(body, "\n"), path)
  vim.fn.setfperm(path, "rwxr-xr-x")
  return path
end

-- `foo.bar!` : edit the leaf's SOURCE -- the authoring half of the namespace.
-- Existing leaf/`.enter` opens straight in a split; a missing one is scaffolded
-- (after a confirm, so a stray `word!` line can't silently create a file) with a
-- shebang skeleton and opened. Returns true if handled (home set), false (prose).
local function edit_namespace(dotted)
  local home = ns_home()
  if home == "" then return false end
  local base = home .. "/" .. (dotted:gsub("%.", "/"))

  -- existing: a leaf file, or a directory's `.enter` (its behavior definition)
  local path = ns_leaf_path(base)
  if not path and vim.fn.isdirectory(base) == 1 then
    local enter = base .. "/.enter"
    path = vim.fn.filereadable(enter) == 1 and enter or nil
    if not path then -- offer to define this folder's `.enter`
      if not M.confirm("bsh: define " .. dotted .. "/.enter ?") then return true end
      path = scaffold_leaf(dotted, enter)
    end
  elseif not path then -- nothing there: scaffold a new leaf (with a typo-guard)
    if not M.confirm("bsh: create command '" .. dotted .. "' ?") then return true end
    path = scaffold_leaf(dotted, base .. (SCAFFOLD[M.scaffold_lang] or SCAFFOLD.sh).ext)
  end

  vim.cmd("split " .. vim.fn.fnameescape(path))
  return true
end

-- Dispatch on the current line. Returns true if something was handled, false to
-- let <CR> fall through to its default.
local function execute_cell(to_buf)
  local buf = vim.api.nvim_get_current_buf()
  local trow = vim.api.nvim_win_get_cursor(0)[1] - 1
  local line = vim.api.nvim_buf_get_lines(buf, trow, trow + 1, false)[1] or ""
  local indent = line:match("^(%s*)")

  -- <CR> on a `log` reference line opens that cell's output buffer in a split.
  local outlink = line:match("(bsh://out/%S+)")
  if outlink then open_out_buffer(outlink); return true end

  -- Cursor inside a `$`/`$$` (or `python $`/`$$`) input fence: run the WHOLE
  -- block (multiline). The owned `out` fence is staged just after the block's
  -- closing ``` (pass that row as the trigger). Checked first so a body line
  -- that happens to look like a `$ ...` trigger doesn't run on its own.
  local fc = input_fence_at(buf, trow)
  if fc then
    if fc.lang == "sh" then
      if fc.session then -- local or remote (`user@host$$`) persistent shell
        run_session(buf, "sh", fc.target, fc.close, fc.indent, fc.body)
      else
        run_shell(buf, fc.close, fc.indent, fc.target, fc.body, to_buf)
      end
    elseif fc.target ~= "" then
      vim.notify("bsh: remote " .. fc.lang .. " cells aren't supported yet",
        vim.log.levels.WARN)
    elseif fc.session then
      run_session(buf, fc.lang, "", fc.close, fc.indent, fc.body)
    else -- one-shot interpreter run
      run_oneshot(buf, fc.close, fc.indent, { M.python, "-c", fc.body })
    end
    return true
  end

  -- inline shell: `[user@host]$ cmd` (one-shot) or `[user@host]$$ cmd` (shared
  -- session, local or remote). One unified match: the marker is `$`/`$$` and the
  -- greedy `%$?` captures the doubled form, so `user@host$$ cmd` parses
  -- target=`user@host` (NOT `user@host$`, which would corrupt the ssh host).
  local stgt, sdbl, scmd = line:match("^%s*(%S-)(%$%$?)%s+(.+)$")
  if scmd then
    if sdbl == "$$" then
      run_session(buf, "sh", stgt, trow, indent, scmd)
    else
      run_shell(buf, trow, indent, stgt, scmd, to_buf)
    end
    return true
  end

  -- `https://…` on its own line : open it in the browser.
  local url = line:match("^%s*(https?://%S+)%s*$")
  if url then
    open_url(url)
    return true
  end

  -- `> instruction` : agentic llm call. The count of leading `>` beyond the
  -- first = how many preceding cells to fold in as context (`>` none, `>>` one,
  -- `>>>` two, …). Output goes in a comment-delimited region below.
  local gts, instruction = line:match("^%s*(>+)%s+(.+)$")
  if instruction then
    run_agent(buf, trow, indent, instruction, #gts - 1)
    return true
  end

  -- `[user@host]: path` listing. To avoid firing on prose like "TODO: fix", the
  -- colon must be the first non-blank char (local) or the target must name a
  -- host (`user@host`). Remote listings therefore use the user@host form.
  local ltarget, lrest = line:match("^%s*(%S-):%s+(.+)$")
  if lrest and (ltarget == "" or ltarget:find("@")) then
    run_list(buf, trow, indent, ltarget, lrest)
    return true
  end

  -- <CR> on an entry inside a `dir`/`tree` fence: open the file / drill into it.
  local open, tag = fence_open(buf, trow)
  if open then
    local trig = vim.api.nvim_buf_get_lines(buf, open - 1, open, false)[1] or ""
    local ttarget, trest = trig:match("^%s*(%S-):%s+(.+)$")
    if not trest then
      -- Not a `:` directive -- maybe a namespace listing (dotted trigger, e.g.
      -- `llm.tools`). Reconstruct its dir under $BSH_HOME and navigate the
      -- entries the same way `:` does, but staying DOTTED: drilling into a subdir
      -- rewrites the trigger to the deeper namespace, files open for editing.
      local nsdot = trig:match("^%s*([%w_][%w_%.%-]*)%s*$")
      -- a namespace listing's trigger carries a trailing dot (`demo.`); strip it
      -- so we never build `demo..child`
      local clean = nsdot and (nsdot:gsub("%.+$", "")) or nil
      local home = clean and ns_home() or ""
      local base = home ~= "" and (home .. "/" .. (clean:gsub("%.", "/"))) or ""
      if base == "" or vim.fn.isdirectory(base) ~= 1 or tag ~= "dir" then return false end
      local entry = (line:gsub("^%s+", "")):gsub("%s+$", "")
      if entry == "" then return false end
      local tindent = trig:match("^(%s*)")
      if entry == "../" then -- walk up one namespace segment (drop to `:` at root)
        local parent = clean:match("^(.+)%.[^.]+$")
        if parent then
          run_namespace(buf, open - 1, tindent, parent .. ".") -- list the parent
        else
          local up = vim.fn.fnamemodify(base, ":h")
          vim.api.nvim_buf_set_lines(buf, open - 1, open, false, { tindent .. ": " .. up })
          run_list(buf, open - 1, tindent, "", up)
        end
      elseif entry:sub(-1) == "/" then -- drill deeper: descend + list (append `.`)
        run_namespace(buf, open - 1, tindent, clean .. "." .. entry:sub(1, -2) .. ".")
      else
        open_entry("", base .. "/" .. entry)
      end
      return true
    end
    local base, flags = parse_list_args(trest)

    local full, isdir
    if tag == "tree" then
      full, isdir = tree_path(buf, open + 1, trow, base)
      if not full then return false end -- root/summary/blank line
    else
      local entry = (line:gsub("^%s+", "")):gsub("%s+$", "")
      if entry == "" then return false end
      isdir = entry:sub(-1) == "/"
      full = join_path(base, isdir and entry:sub(1, -2) or entry)
    end

    if isdir then
      -- rewrite the trigger's path and re-list in place (oil-style navigation),
      -- preserving the cell's mode (tree stays tree) and -H flag
      local tindent = trig:match("^(%s*)")
      local suffix = (flags.tree and " -T" or "") .. (flags.hidden and " -H" or "")
      local newtrig = tindent .. (ttarget ~= "" and (ttarget .. ": ") or ": ") .. full .. suffix
      vim.api.nvim_buf_set_lines(buf, open - 1, open, false, { newtrig })
      run_list(buf, open - 1, tindent, ttarget, full .. suffix)
    else
      open_entry(ttarget, full)
    end
    return true
  end

  -- `foo.bar!` : edit/define a command's source (authoring). Checked before the
  -- run branches; `!` never appears in the run/args forms, and a prose `word!`
  -- is guarded by a confirm before anything is created.
  local nsbang = line:match("^%s*([%w_][%w_%.%-]*)!%s*$")
  if nsbang and edit_namespace(nsbang) then
    return true
  end

  -- `namespace` cell: a dotted identifier resolving under $BSH_HOME, optionally
  -- followed by args (`llm.tools.weather Ankara`, `... > out.txt`, `... | grep C`).
  -- The args go through the shell (see run_ns_exec), so the cell is a true shell
  -- continuation. Checked last and gated on the FIRST token resolving, so prose
  -- (which won't resolve) falls through untouched -- args form tried first.
  local nsname, nsargs = line:match("^%s*([%w_][%w_%.%-]*)%s+(.+)$")
  if nsname and run_namespace(buf, trow, indent, nsname, nsargs, to_buf) then
    return true
  end
  local dotted = line:match("^%s*([%w_][%w_%.%-]*)%s*$")
  if dotted and run_namespace(buf, trow, indent, dotted, nil, to_buf) then
    return true
  end

  return false
end

-- Folding: each fence (opening line through its closing ```) is its OWN fold;
-- the trigger line and surrounding prose stay at level 0 and visible.
-- We force a fold boundary at every fence so that ADJACENT fences with no blank
-- line between them -- e.g. a multiline input fence's closing ``` immediately
-- followed by the ```out result opener -- become two separate folds instead of
-- one merged blob. `>1` starts a fold at an opening fence, `<1` ends it at the
-- closing ```; content scans upward to decide inside (1) vs prose (0).
local OPEN = "^%s*```%S"
local FENCE = "^%s*```%s*$"

function M.foldexpr(lnum)
  local line = vim.fn.getline(lnum)
  if line:match(OPEN) then return ">1" end   -- opening fence starts a new fold
  if line:match(FENCE) then return "<1" end  -- closing ``` ends the fold here
  for l = lnum - 1, 1, -1 do
    local s = vim.fn.getline(l)
    if s:match(OPEN) then return "1" end   -- inside a fence body
    if s:match(FENCE) then return "0" end  -- the fence above was a closer
  end
  return "0"
end

-- Collapsed cells read as `  ▸ out (N lines)` / `  ▸ dir (N entries)`
-- (N = body lines, fences excluded; tag taken from the opening fence).
function M.foldtext()
  local open = vim.fn.getline(vim.v.foldstart)
  local indent = open:match("^(%s*)")
  local tag = open:match("```(%S+)") or "out"
  local n = vim.v.foldend - vim.v.foldstart - 1
  local unit = tag == "dir" and (n == 1 and " entry)" or " entries)")
    or (n == 1 and " line)" or " lines)")
  return indent .. "▸ " .. tag .. " (" .. n .. unit
end

-- Turn ANY buffer into a lab: the cell-running <CR>, comment style and folding,
-- WITHOUT changing its filetype (so an existing markdown file keeps its markdown
-- syntax highlighting). Idempotent -- safe to call more than once on a buffer.
function M.attach(buf)
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
  if vim.b[buf].bsh_attached then return end
  vim.b[buf].bsh_attached = true

  vim.bo[buf].commentstring = "<!-- %s -->"
  -- fold each result fence; start fully open (za on the trigger toggles one)
  vim.api.nvim_buf_call(buf, function()
    vim.opt_local.foldmethod = "expr"
    vim.opt_local.foldexpr = "v:lua.require'bsh'.foldexpr(v:lnum)"
    vim.opt_local.foldtext = "v:lua.require'bsh'.foldtext()"
    vim.opt_local.foldlevel = 99
    vim.opt_local.fillchars:append("fold: ")
  end)

  local function run_here(to_buf)
    if not execute_cell(to_buf) then
      -- not a cell: preserve the default <CR> (down to first non-blank)
      vim.cmd("normal! +")
    end
  end
  vim.keymap.set("n", "<CR>", function() run_here(false) end,
    { buffer = buf, desc = "bsh: run cell (output inline)" })
  -- <C-CR> (and the always-works fallback g<CR>): run with output in a side buffer.
  -- NOTE: many terminals don't pass <C-CR> distinctly from <CR> unless they speak
  -- the kitty keyboard protocol -- hence the g<CR> fallback (see README).
  vim.keymap.set("n", "<C-CR>", function() run_here(true) end,
    { buffer = buf, desc = "bsh: run cell (output to side buffer)" })
  vim.keymap.set("n", "g<CR>", function() run_here(true) end,
    { buffer = buf, desc = "bsh: run cell (output to side buffer)" })
end

M.config = function()
  -- `*.bsh` is the dedicated filetype; `*.bsh.md` / `*.bsh.markdown` stay
  -- markdown -- so they keep markdown highlighting -- but get buffer-shell
  -- powers via M.attach below.
  vim.filetype.add({
    extension = { bsh = "bsh" },
    pattern = {
      ["%.bsh%.md$"] = "markdown",
      ["%.bsh%.markdown$"] = "markdown",
    },
  })

  -- attach on the dedicated filetype...
  vim.api.nvim_create_autocmd("FileType", {
    pattern = "bsh",
    callback = function(args) M.attach(args.buf) end,
  })
  -- ...and on the `*.bsh.md` markdown convention (filename, not filetype, since
  -- the compound-filetype FileType event we can't rely on never enters into it).
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
    pattern = { "*.bsh.md", "*.bsh.markdown" },
    callback = function(args) M.attach(args.buf) end,
  })

  -- tear a buffer's persistent `$$` shell down when the buffer is wiped.
  vim.api.nvim_create_autocmd("BufWipeout", {
    callback = function(args) M.stop_session(args.buf) end,
  })

  -- :Bsh  -> scratch lab buffer to play in.
  -- :Bsh! -> attach lab powers to the CURRENT buffer in place (any filetype),
  --             so an existing markdown/notes file becomes runnable on demand.
  vim.api.nvim_create_user_command("Bsh", function(o)
    if o.bang then
      M.attach(0)
    else
      vim.cmd("enew")
      vim.bo.filetype = "bsh"
      vim.bo.bufhidden = "hide"
    end
  end, { bang = true, desc = "open a scratch bsh buffer (! = attach to current)" })
end

return M
