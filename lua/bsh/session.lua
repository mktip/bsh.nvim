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

-- The persistent login shell a remote/transport `sh` session terminates in. Run
-- through the SAME route engine as one-shots (job.build_argv), so a `$$` session
-- composes over any transport -- `docker@id$$`, `web@prod/docker@api$$` -- exactly
-- like a `$`. `exec ${SHELL:-/bin/sh} -l` replaces the hop's wrapper `sh -lc` with
-- a login shell reading the (kept-open) stdin, which is what makes it persistent.
local SESSION_SH = "exec ${SHELL:-/bin/sh} -l"

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
    -- local: a login shell (env loads once). remote/transport (`user@host$$`,
    -- `docker@id$$`, `web@prod/docker@api$$`): the SAME login shell, reached
    -- through the route engine -- so a persistent session works over anything a
    -- one-shot does. cmds arrive on the kept-open stdin (no pty).
    argv = function(_, target)
      if target == "" then return { vim.o.shell, "-l" } end
      return job.build_argv(target, SESSION_SH)
    end,
    init = function(s) vim.fn.chansend(s.job, "exec 2>&1\n") end,
    -- The sentinel carries BOTH the exit code AND `$PWD` -- so we learn the
    -- session's cwd by reading the shell itself (never by parsing `cd`, which a
    -- dynamic path or a subshell would defeat). The pwd field is parsed back in
    -- sess_start and surfaced as the cwd badge.
    send = function(s, code)
      vim.fn.chansend(s.job, code ..
        "\nprintf '\\n__BSH_" .. s.token .. "__:%d:%s\\n' \"$?\" \"$PWD\"\n")
    end,
  },
  python = {
    argv = function(token, _) return { config.python, "-u", "-c", (DRIVER_PY:gsub("@TOKEN@", token)) } end,
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
local function set_prompt_badge(buf, row, target, cwd)
  if not (row and cwd and cwd ~= "" and vim.api.nvim_buf_is_valid(buf)) then return end
  if row < 0 or row >= vim.api.nvim_buf_line_count(buf) then return end
  local label = (target ~= "" and (target .. ":") or "") .. cwd
  pcall(vim.api.nvim_buf_clear_namespace, buf, promptns, row, row + 1)
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
  local s = { lang = lang, target = target, spec = spec, acc = "", busy = false, queue = {},
              token = string.format("%08x", math.random(0, 0xffffffff)) }
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
          local lines = vim.split(body:gsub("\r", ""), "\n", { plain = true })
          while #lines > 0 and lines[#lines] == "" do table.remove(lines) end
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
            fill_fence(buf, item.mark, item.indent, lines)
          end
        end
        sess_pump(buf, key) -- drain anything queued behind it
      end
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
-- session fills once on unit completion rather than streaming, so we hand the
-- buffer sink to the queue item and the pump calls it instead of `fill_fence`.
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
    item = { cmd = cmd, mark = mark, indent = indent, prow = prow }
  end
  table.insert(sessions[buf][key].queue, item)
  sess_pump(buf, key)
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
