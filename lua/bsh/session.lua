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
  local jb = vim.fn.jobstart(spec.argv(s.token, target), {
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
function M.run_session(buf, lang, target, trow, indent, cmd, to_buf)
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
    item = { cmd = cmd, mark = mark, indent = indent, sink = sink }
  else
    local mark = stage_fence(buf, trow, indent, "out", "...running (session)...")
    item = { cmd = cmd, mark = mark, indent = indent }
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
