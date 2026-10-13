-- Persistent language sessions: a `$$` cell runs in ONE long-lived process per
-- (buffer, language, target), so state (env, cd, Python vars/imports, a venv)
-- carries across cells. Each unit is fed on stdin and framed by a random sentinel
-- line; output is sliced out and dropped in the cell's fence (or a side buffer).
local M = {}

local fence = require("bsh.fence")
local job = require("bsh.job")
local config = require("bsh.config")
local ns, inflight = fence.ns, fence.inflight
local stage_fence, fill_fence = fence.stage_fence, fence.fill_fence
local doc_cwd, existing_log_link, begin_buffer_run = job.doc_cwd, job.existing_log_link, job.begin_buffer_run

local sessions = {} -- [buf] = { [lang] = { job, spec, token, acc, busy, current, queue } }

-- A separate extmark namespace for the cwd prompt badge (eol virt_text on a `$$`
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
-- the route engine, so a `$$` composes over any transport (`docker@id$$`,
-- `web@prod/docker@api$$`) exactly like a `$`.
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
    init = function() end,
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

-- Render the cwd prompt badge for a just-finished `sh` `$$` cell: eol virt_text
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
  if not (item and s.acc ~= "") then return end
  local marker = "__BSH_" .. s.token .. "__:"
  local cut = s.acc:match("^.*()\n") -- index of the last newline, or nil
  local tail = cut and s.acc:sub(cut + 1) or s.acc
  local held = tail ~= "" and (marker:sub(1, #tail) == tail or tail:sub(1, #marker) == marker)
  local text = held and (cut and s.acc:sub(1, cut - 1) or "") or s.acc
  local lines = body_lines(text)
  if #lines == 0 or item.last == text then return end
  item.last = text
  vim.schedule(function()
    if item.done or not vim.api.nvim_buf_is_valid(buf) then return end -- finished since: final fill owns it
    if item.sink then
      item.sink(lines, false)
      return
    end
    local pos = vim.api.nvim_buf_get_extmark_by_id(buf, ns, item.mark, {})
    if not pos[1] then return end -- fence gone (re-run / cleared): stale
    local out = {}
    for _, l in ipairs(lines) do out[#out + 1] = item.indent .. l end
    vim.api.nvim_buf_set_lines(buf, pos[1], pos[1] + item.n, false, out)
    item.n = #out
  end)
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
  local s = {
    lang = lang,
    target = target,
    spec = spec,
    acc = "",
    busy = false,
    queue = {},
    token = string.format("%08x", math.random(0, 0xffffffff))
  }
  local jb = vim.fn.jobstart(spec.argv(s.token, target), {
    cwd = doc_cwd(buf),
    on_stdout = function(_, data)
      if not data then return end
      s.acc = s.acc .. table.concat(data, "\n")
      while true do
        -- sentinel: `__BSH_<token>__:<rc>[:<pwd>]`. The pwd field is sh-only (the
        -- `:?` makes it optional so the python driver's `:<rc>` sentinel matches too).
        local a, b, rc, pwd = s.acc:find("\n__BSH_" .. s.token .. "__:(%d+):?([^\r\n]*)\r?\n")
        if not a then break end
        local body = s.acc:sub(1, a - 1) -- everything before the sentinel line
        s.acc = s.acc:sub(b + 1)
        local item = s.current
        s.busy, s.current = false, nil
        if item then
          item.done = true -- queued streaming paints for it become no-ops
          local lines = body_lines(body)
          if tonumber(rc) ~= 0 then lines[#lines + 1] = "[exit " .. rc .. "]" end
          if pwd ~= "" then -- shell told us where it is now -> refresh the cwd badge
            s.cwd = pwd
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
    on_exit = function() if sessions[buf] then sessions[buf][key] = nil end end,
  })
  if jb <= 0 then return nil end
  s.job = jb
  spec.init(s)
  sessions[buf] = sessions[buf] or {}
  sessions[buf][key] = s
  return s
end

-- Queue `cmd` on this buffer's `lang`@`target` session. Output lands inline in an
-- `out` fence; with `to_buf` (<C-CR>) -- or sticky, if the cell already owns a
-- `log` fence -- in a side buffer, exactly like `$`. A `$$` fence is pure output
-- (nothing to navigate inside it), so the only difference from `$` is that the
-- session streams partial output (see stream_partial) and fills on completion, so
-- we hand the buffer sink to the queue item and the pump calls it instead of
-- `fill_fence`.
-- `prow` (0-indexed, optional) is the cell's PROMPT line -- the `$$`/```$$` line
-- the badge attaches to. Only `sh` sessions surface a cwd badge (it rides the
-- shell's `$PWD`); a nil `prow` just skips it.
function M.run_session(buf, lang, target, trow, indent, cmd, to_buf, prow)
  local key = skey(lang, target)
  if not (sessions[buf] and sessions[buf][key]) then
    if not sess_start(buf, lang, target) then
      vim.notify("bsh: could not start " .. lang .. " session", vim.log.levels.ERROR)
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

-- Send SIGINT to the right process for a session's CURRENTLY RUNNING unit, the
-- Ctrl-C equivalent that interrupts the command while keeping the session (env,
-- cwd, Python globals) alive:
--   python : signal the interpreter itself. Our driver execs each cell inside a
--            `try/except BaseException`, so KeyboardInterrupt is caught, printed,
--            and the read loop continues with the globals dict intact -- an
--            infinite-loop cell is interruptible without losing state.
--   sh     : signal the shell's foreground CHILD(ren) (`pgrep -P`), not the shell:
--            a non-interactive shell has no job control, so SIGINT must hit the
--            child directly. The shell then runs its sentinel printf (rc 130) and
--            keeps reading stdin. (A pure shell-builtin loop with no child can't be
--            interrupted this way -- reset the session instead.)
local function interrupt_proc(s)
  local ok, pid = pcall(vim.fn.jobpid, s.job)
  if not ok or not pid or pid <= 0 then return end
  local function sigint(p) vim.fn.system({ "kill", "-INT", tostring(p) }) end
  if s.lang ~= "sh" then
    sigint(pid); return
  end
  local kids = vim.fn.systemlist({ "pgrep", "-P", tostring(pid) })
  if vim.v.shell_error == 0 and #kids > 0 then
    for _, k in ipairs(kids) do
      local n = tonumber(k); if n then sigint(n) end
    end
  else
    sigint(pid)
  end
end

-- Interrupt (SIGINT) the running command in this buffer's `lang`@`target` session.
-- No-op unless the session exists AND is busy (a SIGINT to an idle interpreter
-- waiting on stdin would escape its read loop and kill it). Returns true if a
-- signal was sent. The session keeps running; its sentinel arrives normally, so
-- the cell fills with whatever it produced plus the interrupt's exit note.
--
-- REMOTE sessions (`target ~= ""`) are deliberately skipped: the process we can
-- signal locally is the ssh client, not the interpreter on the far side, so a
-- SIGINT would tear the whole session down instead of interrupting one command.
-- Returns false so the caller can steer the user to `:BshReset` (a fresh remote
-- interpreter) -- the only clean recovery until we forward signals over the hop.
function M.interrupt_session(buf, lang, target)
  if target ~= "" then return false end
  local s = sessions[buf] and sessions[buf][skey(lang, target)]
  if not (s and s.busy) then return false end
  pcall(interrupt_proc, s)
  return true
end

-- RESET a session: kill its process and forget it, so the next `$$`/`%%` (or
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

return M
