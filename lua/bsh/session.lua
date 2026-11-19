-- Persistent language sessions: a `%%` cell runs in ONE long-lived process per
-- (buffer, language, target), so state (env, cd, Python vars/imports, a venv)
-- carries across cells. Each unit is fed on stdin and framed by a random sentinel
-- line; output is sliced out and dropped in the cell's fence (or a side buffer).
local M = {}

local fence = require("bsh.fence")
local job = require("bsh.job")
local config = require("bsh.config")
local cell = require("bsh.cell")
local util = require("bsh.util")
local ns, inflight = fence.ns, fence.inflight
local stage_fence, fill_fence = fence.stage_fence, fence.fill_fence
local doc_cwd, existing_log_link, begin_buffer_run = job.doc_cwd, job.existing_log_link, job.begin_buffer_run

local sessions = {} -- [buf] = { [lang] = { job, spec, token, acc, busy, current, queue } }

-- A separate extmark namespace for the cwd prompt badge (eol virt_text on a `%%`
-- cell's prompt line), so it never tangles with the fence/inflight machinery.
local promptns = vim.api.nvim_create_namespace("bsh_prompt")

-- The `sh` session driver (POSIX sh, so it runs under bash/zsh/dash/ash alike).
-- It separates the two jobs a single stdin pipe used to do: bsh's COMMAND channel
-- is moved to fd 3, and the commands themselves get /dev/null as stdin. Without
-- this a cell that reads stdin (`mpirun`, `ssh`, a bare `cat`) inherits the
-- command pipe, steals the bytes queued behind it (the sentinel included) and
-- hangs the session. Cells arrive as lines closed by an @TOKEN@ end marker, are
-- `eval`ed in THIS shell (so cd/export/functions persist), and fd 3 is closed for
-- the eval so no child -- or backgrounded job -- can read the channel. Explicit
-- redirects inside a cell (`cmd < file`, pipes, heredocs) work as in any shell.
local DRIVER_SH = [[
exec 3<&0 </dev/null 2>&1
printf '__BSH_@TOKEN@__:pid:%d\n' "$$"
while :; do
  __c=
  while :; do
    IFS= read -r __l <&3 || exit 0
    [ "$__l" = "__BSH_END_@TOKEN@__" ] && break
    __c="$__c$__l
"
  done
  eval "$__c" 3<&-
  __r=$?
  printf '\n__BSH_@TOKEN@__:%d:%s\n' "$__r" "$PWD"
done
]]

-- Shells whose syntax isn't POSIX: the driver can't run under them, so those
-- users (and remote hosts whose $SHELL is one) get /bin/sh -l instead.
local NON_POSIX = { fish = true, csh = true, tcsh = true, nu = true, xonsh = true, elvish = true, pwsh = true }

local function local_shell()
  local sh = vim.o.shell
  return NON_POSIX[vim.fn.fnamemodify(sh, ":t")] and "/bin/sh" or sh
end

-- Remote/transport: the SAME driver, run as a login shell on the far side through
-- the route engine, so a `%%` composes over any transport (`docker@id%%`,
-- `web@prod/docker@api%%`) exactly like a `%`.
local function remote_command(token)
  local driver = DRIVER_SH:gsub("@TOKEN@", token)
  return 'case "${SHELL##*/}" in fish|csh|tcsh|nu|xonsh|elvish|pwsh) __s=/bin/sh;; *) __s=${SHELL:-/bin/sh};; esac; '
    .. "exec \"$__s\" -l -c " .. vim.fn.shellescape(driver)
end

-- Python driver run as `python -u -c <this>`; @TOKEN@ is substituted per session.
-- Reads LENGTH-PREFIXED code chunks and execs each into a persistent globals dict
-- (length-framing makes multiline/indentation a non-issue), printing the sentinel
-- itself; stderr is aliased to stdout for order.
local DRIVER_PY = [[
import os, sys, traceback
_in = sys.stdin.buffer
sys.stderr = sys.stdout              # keep tracebacks/prints in stream order
sys.stdout.write("__BSH_@TOKEN@__:pid:%d\n" % os.getpid()); sys.stdout.flush()
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

-- A `spec` per language plugs in how to start the process and submit code/emit the
-- sentinel; the streaming/parsing in sess_start is shared.
local SPECS = {
  sh = {
    -- local: a login shell running DRIVER_SH. remote/transport: the same driver
    -- reached through the route engine. Cells are fed on the kept-open stdin
    -- (no pty) as lines + an end marker; see DRIVER_SH for why stdin is split.
    argv = function(token, target)
      local driver = DRIVER_SH:gsub("@TOKEN@", token)
      if target == "" then return { local_shell(), "-l", "-c", driver } end
      return job.build_argv(target, remote_command(token))
    end,
    init = function(_) end,
    -- The sentinel (printed by the driver) carries BOTH the exit code AND `$PWD`
    -- -- so we learn the session's cwd by reading the shell itself (never by
    -- parsing `cd`, which a dynamic path or a subshell would defeat). The pwd
    -- field is parsed back in sess_start and surfaced as the cwd badge.
    send = function(s, code)
      vim.fn.chansend(s.job, code .. "\n__BSH_END_" .. s.token .. "__\n")
    end,
  },
  python = {
    -- local: the interpreter directly. remote (`python user@host%%`): the SAME
    -- driver, routed through the engine so its length-prefixed stdin protocol
    -- flows over ssh -T (binary-clean, stdin kept open) -- a persistent remote
    -- Python whose globals survive across cells, exactly like the local one.
    argv = function(token, target)
      local driver = DRIVER_PY:gsub("@TOKEN@", token)
      if target == "" then return { config.python, "-u", "-c", driver } end
      return job.build_argv(target, config.python .. " -u -c " .. vim.fn.shellescape(driver))
    end,
    init = function(_) end,
    send = function(s, code) -- length-prefixed chunk: header line + exact bytes
      vim.fn.chansend(s.job, tostring(#code) .. "\n" .. code)
    end,
  },
}

-- A language from config.languages: its REPL runs along the route (stderr into
-- stdout, so errors show in the cell), each block is followed by the language's
-- own `print` of the end marker, and the output is cleaned of the REPL's prompt
-- (L.prompt) and, with L.echo, of the input lines it echoes back. A hidden first
-- sync swallows its startup banner. It reports no pid, so <C-c> can't interrupt
-- it (reset it with <C-k>), and no exit code.
local function generic_spec(lang)
  local L = (config.languages or {})[lang]
  if not L then return nil end
  local P = L.prompt ~= "" and L.prompt or nil
  local function unprompt(l)
    while P and l:sub(1, #P) == P do l = l:sub(#P + 1) end
    return l
  end
  return {
    warmup = true,
    argv = function(_, target)
      return job.build_argv(target, (L.session or L.cmd) .. " 2>&1")
    end,
    init = function(_) end,
    send = function(s, code)
      local mark = L.print:format("__BSH_" .. s.token .. "__:0")
      s.sent = vim.split(code, "\n", { plain = true })
      s.sent[#s.sent + 1] = mark
      vim.fn.chansend(s.job, code .. "\n" .. mark .. "\n")
    end,
    -- the end marker may come after a prompt on its line (`> __BSH_..:0`)
    find = function(hay, token)
      local init = 1
      while true do
        local a, b, rc = hay:find("__BSH_" .. token .. "__:(%d+)\r?\n", init)
        if not a then return nil end
        local ls = a
        while ls > 1 and hay:sub(ls - 1, ls - 1) ~= "\n" do ls = ls - 1 end
        if ls > 1 and unprompt(hay:sub(ls, a - 1)) == "" then return ls - 1, b, rc, "" end
        init = b + 1
      end
    end,
    clean = function(lines, s)
      local out, j = {}, 1
      for _, l in ipairs(lines) do
        l = unprompt(l)
        if L.echo and s.sent and s.sent[j] ~= nil and l == s.sent[j] then
          j = j + 1 -- the REPL echoing what we sent
        else
          out[#out + 1] = l
        end
      end
      while #out > 0 and out[#out]:match("^%s*$") do table.remove(out) end
      return out
    end,
  }
end

-- A session is keyed per buffer by language AND target, so a local bash session
-- and a `user@host` remote one (or two different hosts) coexist independently.
local function skey(lang, target)
  return target ~= "" and (lang .. "@" .. target) or lang
end

-- Render the cwd prompt badge for a just-finished `sh` `%%` cell: eol virt_text
-- on its prompt line (`row`, 0-indexed), reading like the shell prompt it mirrors
-- -- `web@prod:/var/log` remote, just the path locally. We clear the row's prior
-- badge first so re-running a cell replaces rather than stacks.
--
-- Off unless `config.prompt_badge` is set. The clear still runs when it is off, so
-- flipping the option (or reloading with it off) drops badges an earlier session
-- already painted instead of stranding them until the buffer is reopened.
local function set_prompt_badge(buf, row, target, cwd)
  if not (row and vim.api.nvim_buf_is_valid(buf)) then return end
  if row >= 0 and row < vim.api.nvim_buf_line_count(buf) then
    pcall(vim.api.nvim_buf_clear_namespace, buf, promptns, row, row + 1)
  end
  if not config.prompt_badge then return end
  if not (cwd and cwd ~= "") then return end
  if row < 0 or row >= vim.api.nvim_buf_line_count(buf) then return end
  local label = (target ~= "" and (target .. ":") or "") .. cwd
  pcall(vim.api.nvim_buf_set_extmark, buf, promptns, row, 0, {
    virt_text = { { "  " .. label, "Comment" } },
    virt_text_pos = "eol",
    -- A zero-width mark at col 0 would otherwise shift onto a neighbouring line
    -- when its prompt line is deleted, orphaning the badge. `invalidate` hides it
    -- once its range is gone; `undo_restore = false` deletes it outright.
    invalidate = true,
    undo_restore = false,
  })
end

-- Split a session's raw output into display lines: strip CRs and trailing blanks.
local function body_lines(body)
  local lines = vim.split(body:gsub("\r", ""), "\n", { plain = true })
  while #lines > 0 and lines[#lines] == "" do table.remove(lines) end
  return lines
end

-- Live-paint the running cell's output as it arrives, like a one-shot `%` does.
-- The shared pipe means the sentinel can arrive split across chunks, so only
-- COMPLETE lines are painted, plus a trailing partial line unless it could be the
-- start of the sentinel (then it is held back until the next chunk settles it).
-- `item.n` tracks how many body lines the fence occupies (1 = the placeholder), so
-- each repaint -- and the final fill -- replaces exactly what was painted.
local function stream_partial(buf, s)
  local item = s.current
  if not (item and s.acc ~= "") or item.hidden then return end
  local marker = "__BSH_" .. s.token .. "__:"
  local cut = s.acc:match("^.*()\n") -- index of the last newline, or nil
  local tail = cut and s.acc:sub(cut + 1) or s.acc
  local held = tail ~= "" and (marker:sub(1, #tail) == tail or tail:sub(1, #marker) == marker)
  local text = held and (cut and s.acc:sub(1, cut - 1) or "") or s.acc
  local lines = body_lines(text)
  if s.spec.clean then lines = s.spec.clean(lines, s) end
  if #lines == 0 or item.last == text then return end
  item.last = text
  vim.schedule(function()
    if item.done or not vim.api.nvim_buf_is_valid(buf) then return end -- finished since: final fill owns it
    if item.sink then
      item.sink(lines, false)
      return
    end
    lines = fence.cap(lines)
    local pos = vim.api.nvim_buf_get_extmark_by_id(buf, ns, item.mark, {})
    if not pos[1] then return end -- fence gone (re-run / cleared): stale
    item.n = fence.paint(buf, pos[1], item.n, item.indent, lines)
  end)
end

local function sess_pump(buf, key)
  local s = sessions[buf] and sessions[buf][key]
  if not s or s.busy then return end
  local item = table.remove(s.queue, 1)
  if not item then return end
  s.busy, s.current = true, item
  -- timed from when it actually starts (not while it waits behind another cell)
  item.timing = require("bsh.status").start(buf, item.prow or -1)
  s.spec.send(s, item.cmd)
end

local function sess_start(buf, lang, target)
  local spec = SPECS[lang] or generic_spec(lang)
  if not spec then return nil, "no such language: " .. lang end
  local key = skey(lang, target)
  local s = {
    lang = lang,
    target = target,
    spec = spec,
    acc = "",
    busy = false,
    queue = {},
    err = {},
    -- OS randomness: math.random is unseeded, so it gave the same token on every
    -- start (and touching its global seed would affect other plugins)
    token = (vim.uv.random(8):gsub(".", function(c) return string.format("%02x", c:byte()) end)),
  }
  local argv = spec.argv(s.token, target)
  if vim.fn.executable(argv[1]) ~= 1 then
    return nil, "`" .. argv[1] .. "` not found"
  end
  local jb = vim.fn.jobstart(argv, {
    cwd = doc_cwd(buf),
    on_stdout = function(_, data)
      if not data then return end
      s.acc = s.acc .. table.concat(data, "\n")
      -- the driver's first line: its pid ON THE FAR SIDE, for interrupts (it
      -- shares the sentinel's prefix, so a half-arrived one is held, not painted)
      if not s.pid then
        local a, b, pid = s.acc:find("__BSH_" .. s.token .. "__:pid:(%d+)\r?\n")
        if a then
          s.pid = tonumber(pid)
          s.acc = s.acc:sub(1, a - 1) .. s.acc:sub(b + 1)
        end
      end
      while true do
        -- sentinel: `__BSH_<token>__:<rc>[:<pwd>]`. The pwd field is sh-only (the
        -- `:?` makes it optional so the python driver's `:<rc>` sentinel matches too).
        -- (searched in "\n" .. acc, so a sentinel that is the very first output --
        -- a block that printed nothing -- still sits at a line start)
        local hay = "\n" .. s.acc
        local a, b, rc, pwd
        if s.spec.find then
          a, b, rc, pwd = s.spec.find(hay, s.token)
        else
          a, b, rc, pwd = hay:find("\n__BSH_" .. s.token .. "__:(%d+):?([^\r\n]*)\r?\n")
        end
        if not a then break end
        local body = hay:sub(2, a - 1) -- everything before the sentinel line
        s.acc = hay:sub(b + 1)
        local item = s.current
        s.busy, s.current = false, nil
        if item and item.hidden then
          item = nil -- the startup sync: its output (a banner) goes nowhere
        end
        if item then
          item.done = true -- queued streaming paints for it become no-ops
          if item.timing then item.timing.done(tonumber(rc)) end
          local lines = body_lines(body)
          if s.spec.clean then lines = s.spec.clean(lines, s) end
          if not item.sink then lines = fence.cap(lines) end -- inline: keep the head
          if tonumber(rc) ~= 0 then lines[#lines + 1] = "[exit " .. rc .. "]" end
          if pwd ~= "" then -- shell told us where it is now -> refresh the cwd badge
            s.cwd = pwd
            s.shell_cwd = pwd -- reported by the shell itself (remote-safe)
            set_prompt_badge(buf, item.prow, s.target, pwd)
          end
          if item.sink then -- <C-CR>: output to a side buffer, not the doc fence
            item.sink(lines, true, tonumber(rc))
            pcall(vim.api.nvim_buf_del_extmark, buf, ns, item.mark)
            if inflight[buf] then inflight[buf][item.mark] = nil end
          else
            -- scheduled so `item.n` is read AFTER any queued streaming paints ran
            vim.schedule(function()
              fill_fence(buf, item.mark, item.indent, lines, function() return item.n end)
            end)
          end
        end
        sess_pump(buf, key) -- drain anything queued behind it
      end
      stream_partial(buf, s) -- no sentinel yet for the running cell: paint what we have
    end,
    -- the driver's own stderr (it routes the cells' stderr to stdout): what the
    -- user needs to see when the session can't start, e.g. `python3: not found`
    on_stderr = function(_, data)
      for _, l in ipairs(data or {}) do
        if l ~= "" then s.err[#s.err + 1] = l end
      end
    end,
    -- The process died on its own (it never started, `exit` in a cell, the
    -- container stopped...). Finalize what was waiting on it so no cell is left
    -- on `...running`. A reset has already forgotten this session and done that.
    on_exit = function(_, code)
      if not (sessions[buf] and sessions[buf][key] == s) then return end
      sessions[buf][key] = nil
      local pending = {}
      if s.current then pending[1] = s.current end
      vim.list_extend(pending, s.queue)
      vim.schedule(function()
        for i, it in ipairs(pending) do
          local lines = i == 1 and s.current and body_lines(s.acc) or {}
          if i == 1 then vim.list_extend(lines, s.err) end
          lines[#lines + 1] = "[session exited " .. code .. "]"
          it.done = true
          if it.timing then it.timing.done(code, "session exited") end
          if it.sink then
            it.sink(lines, true, code)
            pcall(vim.api.nvim_buf_del_extmark, buf, ns, it.mark)
            if inflight[buf] then inflight[buf][it.mark] = nil end
          elseif it.mark then
            fill_fence(buf, it.mark, it.indent, lines, function() return it.n end)
          end
        end
      end)
    end,
  })
  if jb <= 0 then return nil end
  s.job = jb
  spec.init(s)
  -- sync once before the first cell, so a REPL's startup banner isn't its output
  if spec.warmup then table.insert(s.queue, 1, { cmd = "", hidden = true }) end
  sessions[buf] = sessions[buf] or {}
  sessions[buf][key] = s
  return s
end

-- Queue `cmd` on this buffer's `lang`@`target` session. Output lands inline in an
-- `out` fence; with `to_buf` (<C-CR>) -- or sticky, if the cell already owns a
-- `log` fence -- in a side buffer, exactly like `%`. A `%%` fence is pure output
-- (nothing to navigate inside it), so the only difference from `%` is that the
-- session streams partial output (see stream_partial) and fills on completion, so
-- we hand the buffer sink to the queue item and the pump calls it instead of
-- `fill_fence`.
-- `prow` (0-indexed, optional) is the cell's PROMPT line -- the `%%`/```%%` line
-- the badge attaches to. Only `sh` sessions surface a cwd badge (it rides the
-- shell's `$PWD`); a nil `prow` just skips it.
function M.run_session(buf, lang, target, trow, indent, cmd, to_buf, prow)
  local key = skey(lang, target)
  if not (sessions[buf] and sessions[buf][key]) then
    local ok, why = sess_start(buf, lang, target)
    if not ok then -- say so in the cell, where the user is looking
      local mark = stage_fence(buf, trow, indent, "out", "...")
      fill_fence(buf, mark, indent, { "[can't start a " .. lang .. " session: " .. (why or "jobstart failed") .. "]" })
      return
    end
  end
  local link = existing_log_link(buf, trow)
  if link then to_buf = true end -- sticky: keep an opted-in cell on its buffer
  local item
  if to_buf then
    local mark, sink = begin_buffer_run(buf, trow, indent, link)
    item = { cmd = cmd, mark = mark, indent = indent, sink = sink, prow = prow }
  else
    local mark = stage_fence(buf, trow, indent, "out", "...running (session)...")
    item = { cmd = cmd, mark = mark, indent = indent, prow = prow, n = 1 }
  end
  table.insert(sessions[buf][key].queue, item)
  sess_pump(buf, key)
end

-- SIGINT the command running in session `s`, wherever the session lives. The
-- driver reported its own pid on the far side (s.pid), so the signal is sent by a
-- second exec over the SAME route -- `kill` runs next to the session, whether
-- that's here, over ssh, in a container, or in a container on an ssh host.
--   sh:     the driver shell's children (the running command; a pipeline is
--           several), or the shell itself when it has none. The driver
--           survives: it just sees the command exit 130.
--   python: the interpreter; the driver catches KeyboardInterrupt and goes on.
-- (A pure shell-builtin loop with no child can't be interrupted this way --
-- reset the session instead.)
local function interrupt_proc(s)
  local pid = s.pid
  if not pid then return false end -- driver hasn't started yet
  local cmd
  if s.lang == "sh" then
    cmd = ("k=$(pgrep -P %d 2>/dev/null || ps -A -o pid= -o ppid= 2>/dev/null"
      .. " | awk '$2 == %d { print $1 }'); kill -INT ${k:-%d}"):format(pid, pid, pid)
  else
    cmd = ("kill -INT %d"):format(pid)
  end
  vim.system(job.build_argv(s.target, cmd), { text = true })
  return true
end

-- Interrupt (SIGINT) the running command in this buffer's `lang`@`target` session.
-- No-op unless the session exists AND is busy (a SIGINT to an idle interpreter
-- waiting on stdin would escape its read loop and kill it). Returns true if a
-- signal was sent. The session keeps running; its sentinel arrives normally, so
-- the cell fills with whatever it produced plus the interrupt's exit note.
function M.interrupt_session(buf, lang, target)
  local s = sessions[buf] and sessions[buf][skey(lang, target)]
  if not (s and s.busy) then return false end
  local ok, sent = pcall(interrupt_proc, s)
  return ok and sent
end

-- RESET a session: kill its process and forget it, so the next `%%`/`%%` (or
-- ```python %%```) run starts a fresh interpreter -- clean env, cleared Python
-- globals, cwd back to the doc dir. Any in-flight/queued cells get their staged
-- fences finalised to `[session reset]` rather than left dangling on "...running...".
-- Works whether or not the session is busy. Returns true if a session existed.
function M.reset_session(buf, lang, target)
  local key = skey(lang, target)
  local s = sessions[buf] and sessions[buf][key]
  if not s then return false end
  local pending = {}
  if s.current then pending[#pending + 1] = s.current end
  for _, it in ipairs(s.queue) do pending[#pending + 1] = it end
  for _, it in ipairs(pending) do
    if it.timing then it.timing.done(130, "reset") end
    if it.sink then
      it.sink({ "[session reset]" }, true, 130)
      pcall(vim.api.nvim_buf_del_extmark, buf, ns, it.mark)
      if inflight[buf] then inflight[buf][it.mark] = nil end
    elseif it.mark then
      it.done = true
      fill_fence(buf, it.mark, it.indent, { "[session reset]" }, function() return it.n end)
    end
  end
  if s.job then pcall(vim.fn.jobstop, s.job) end -- on_exit also nils the slot
  if sessions[buf] then sessions[buf][key] = nil end
  return true
end

-- The buffer's live sessions, as { lang, target, busy } records -- used by the
-- dispatcher to disambiguate / fall back when the cursor isn't on a session cell.
-- Where the (buf, lang, target) session's shell is right now, as last reported
-- by the shell itself; nil if there's no session or it hasn't run a cell yet.
-- (A remote session's starting dir is its own $HOME, which we don't know here.)
function M.session_cwd(buf, lang, target)
  local s = sessions[buf] and sessions[buf][skey(lang, target)]
  return s and s.shell_cwd or nil
end

function M.list_sessions(buf)
  local out = {}
  if sessions[buf] then
    for _, s in pairs(sessions[buf]) do
      out[#out + 1] = { lang = s.lang, target = s.target, busy = s.busy }
    end
  end
  return out
end

-- Reset every session in the buffer (the :BshReset! escape hatch). Returns count.
function M.reset_all(buf)
  if not sessions[buf] then return 0 end
  local keys = {}
  for _, s in pairs(sessions[buf]) do keys[#keys + 1] = { s.lang, s.target } end
  for _, kt in ipairs(keys) do M.reset_session(buf, kt[1], kt[2]) end
  return #keys
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

-- The commands on the session under the cursor: :BshReplay, :BshCancel, :BshReset.

-- If the cursor sits on a persistent-session cell, return its { lang, target }.
-- Two cell shapes carry a session: a multiline input fence with the `%%` suffix
-- (```python %%```, ```%%```) and the inline doubled marker (`%% cmd`,
-- `user@host%% cmd`). Anything else (one-shots, prose, output fences) -> nil.
local function classify_session(buf, row)
  local fc = cell.input_fence_at(buf, row)
  if fc and fc.session then return { lang = fc.lang, target = fc.target } end
  local c = cell.parse(vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or "")
  if c and c.kind == "shell" and c.session then return { lang = "sh", target = c.target } end
  return nil
end

local function session_label(c)
  return (c.target ~= "" and (c.target .. " ") or "") .. c.lang
end

-- Collect, in DOCUMENT ORDER, every session cell at or above `upto` whose
-- (lang, target) matches `want` -- the units that, replayed in sequence, rebuild
-- the state a far-down cell depends on. Two shapes carry a session: a ```lang %%``
-- input fence and an inline `%%`/`target%% cmd` line (always `sh`). We walk
-- top-down, skipping each fenced block as a whole (by its closing ```), so an
-- ```out result body that happens to contain a `%`-looking line is never mistaken
-- for a trigger. Each entry mirrors the args run_session takes.
local function collect_session_cells(buf, upto, want)
  local total = vim.api.nvim_buf_line_count(buf)
  local function gl(r) return vim.api.nvim_buf_get_lines(buf, r, r + 1, false)[1] or "" end
  local cells, r = {}, 0
  while r <= upto and r < total do
    local line = gl(r)
    if line:match("^%s*```%S") then
      -- an opening fence: find its closer and skip the whole block either way
      local close = total - 1
      for rr = r + 1, total - 1 do
        if gl(rr):match("^%s*```%s*$") then close = rr; break end
      end
      local lang, target, sess = util.parse_runmarker(vim.trim(line:match("^%s*```(.*)$") or ""), config.marker)
      if lang and sess and lang == want.lang and target == want.target then
        cells[#cells + 1] = {
          trow = close, prow = r, indent = line:match("^(%s*)"),
          cmd = table.concat(vim.api.nvim_buf_get_lines(buf, r + 1, close, false), "\n"),
        }
      end
      r = close + 1
    else
      -- an inline session line is always `sh`; only collect when that's wanted
      local c = cell.parse(line)
      if c and c.kind == "shell" and c.session and want.lang == "sh" and c.target == want.target then
        cells[#cells + 1] = { trow = r, prow = r, indent = c.indent, cmd = c.body }
      end
      r = r + 1
    end
  end
  return cells
end

-- :BshReplay / <localleader>r — replay this session from the top THROUGH the cell
-- under the cursor, into a FRESH interpreter. We reset the session first (so the
-- replay starts from clean state) then enqueue every matching cell in document
-- order; M.lua's FIFO pump runs them one after another, each filling its own
-- fence as it completes. The point: after a :BshReset (or reopening the file) a
-- far-down cell depends on imports/vars/`cd` from earlier cells that no longer
-- live in the interpreter -- this rebuilds them in one keystroke.
function M.replay_here()
  local buf = vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local c = classify_session(buf, row)
  if not c then
    vim.notify("bsh: put the cursor on a session (%% / ```%% ) cell to replay", vim.log.levels.WARN)
    return
  end
  local cells = collect_session_cells(buf, row, c)
  if #cells == 0 then return end
  M.reset_session(buf, c.lang, c.target) -- replay into a clean interpreter
  for _, it in ipairs(cells) do
    M.run_session(buf, c.lang, c.target, it.trow, it.indent, it.cmd, false, it.prow)
  end
  vim.notify(("bsh: replaying %d %s cell%s"):format(#cells, session_label(c), #cells == 1 and "" or "s"))
end

-- <C-c> / :BshCancel — cancel the running cell under the cursor. A one-shot
-- (`%`) is stopped outright; a session cell's running command is INTERRUPTED
-- (SIGINT) so the session itself survives. Falls back to the sole busy session in
-- the buffer when the cursor isn't on a recognisable cell.
function M.cancel_here()
  local buf = vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  if job.cancel_at(buf, row) then return end
  local c = classify_session(buf, row)
  if c and M.interrupt_session(buf, c.lang, c.target) then
    vim.notify("bsh: interrupted " .. session_label(c) .. " session (SIGINT)")
    return
  end
  local busy = {}
  for _, s in ipairs(M.list_sessions(buf)) do if s.busy then busy[#busy + 1] = s end end
  if #busy == 1 and M.interrupt_session(buf, busy[1].lang, busy[1].target) then
    vim.notify("bsh: interrupted " .. session_label(busy[1]) .. " session (SIGINT)")
    return
  end
  vim.notify("bsh: no running cell under the cursor", vim.log.levels.WARN)
end

-- <localleader>R / :BshReset[!] — reset (restart) the session for the cell under
-- the cursor, so the next run gets a fresh interpreter. `!` resets every session
-- in the buffer. With one session and an ambiguous cursor we reset it anyway;
-- with several we refuse and point at `!` rather than guess.
function M.reset_here(all)
  local buf = vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  if all then
    local n = M.reset_all(buf)
    vim.notify("bsh: reset " .. n .. " session" .. (n == 1 and "" or "s"))
    return
  end
  local c = classify_session(buf, row)
  if c and M.reset_session(buf, c.lang, c.target) then
    vim.notify("bsh: reset " .. session_label(c) .. " session")
    return
  end
  local list = M.list_sessions(buf)
  if #list == 0 then
    vim.notify("bsh: no session here", vim.log.levels.WARN)
  elseif #list == 1 then
    M.reset_session(buf, list[1].lang, list[1].target)
    vim.notify("bsh: reset " .. session_label(list[1]) .. " session")
  else
    vim.notify("bsh: multiple sessions — put the cursor on a session cell, or :BshReset! to reset all",
      vim.log.levels.WARN)
  end
end

return M
