-- Cancelling a running cell (<C-c>/:BshCancel) and resetting a persistent
-- session (<localleader>R/:BshReset). One-shots are stopped; sessions are
-- interrupted (SIGINT, env survives) or reset (fresh interpreter).
local H = require("tests.helpers")
local eq = MiniTest.expect.equality
local child = H.child()
local T = H.set(child)

-- Feed <CR> on `row` (1-indexed) but DON'T wait for the job to finish -- used for
-- long-running cells we intend to cancel mid-flight.
local function start(row)
  child.lua(
    [[local row = ...
      vim.api.nvim_win_set_cursor(0, { row, 0 })
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<CR>', true, false, true), 'x', false)
      vim.wait(200)]],
    { row }
  )
end

-- inflight/sessions are keyed by the real bufnr (what the dispatcher passes), so
-- the specs call the engine with the actual buffer, mirroring production.
-- wait (up to 3s) until some buffer line contains `text`
local function wait_for(text)
  child.lua([[local t = ...
    vim.wait(3000, function()
      for _, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
        if l:find(t, 1, true) then return true end
      end
    end, 20)]], { text })
end

local function bufeval(c, expr)
  return c.lua_get("(function() local b = vim.api.nvim_get_current_buf(); return " .. expr .. " end)()")
end

T["cancel stops a one-shot and notes [cancelled]"] = function()
  H.bootstrap(child, { name = "x.bsh", lines = { "% sleep 5" } })
  start(1)
  -- still running: an `out` fence with the placeholder, job in flight
  eq(bufeval(child, "require('bsh.fence').inflight[b] ~= nil and next(require('bsh.fence').inflight[b]) ~= nil"), true)
  eq(bufeval(child, "require('bsh.job').cancel_at(b, 0)"), true) -- cursor on the trigger (row 0)
  child.lua("vim.wait(500)")
  eq(H.rowof(child, "%[cancelled%]") ~= nil, true)
end

T["reset gives a fresh shell session (env cleared)"] = function()
  H.bootstrap(child, { name = "r.bsh", lines = { "%% X=hi", "", "%% echo $X" } })
  H.run(child, H.rowof(child, "^%%%% X=hi$"))
  H.run(child, H.rowof(child, "echo %$X"))
  eq(H.rowof(child, "^hi$") ~= nil, true) -- env carried across cells
  eq(bufeval(child, "require('bsh.session').reset_session(b, 'sh', '')"), true)
  -- after reset the session is a brand-new shell, so $X is unset: the re-run cell
  -- produces no output (the prior `hi` is replaced in place)
  H.run(child, H.rowof(child, "echo %$X"))
  eq(H.rowof(child, "no output") ~= nil, true)
end

T["reset_session is a no-op (false) when there is no session"] = function()
  H.bootstrap(child, { name = "n.bsh", lines = { "% echo hi" } })
  eq(bufeval(child, "require('bsh.session').reset_session(b, 'sh', '')"), false)
end

T["<C-c> interrupts a session at the end of a nested route, which survives"] = function()
  H.bootstrap(child, { name = "rr.bsh", lines = { "loc@a/loc@b%% X=kept", "", "loc@a/loc@b%% sleep 20", "", "loc@a/loc@b%% echo $X" } })
  child.lua("require('bsh').transports.loc = { 'sh', '-c', '{cmd}' }")
  H.run(child, 1)
  start(H.rowof(child, "sleep 20"))
  eq(bufeval(child, "require('bsh.session').interrupt_session(b, 'sh', 'loc@a/loc@b')"), true)
  wait_for("[exit 130]")
  eq(H.rowof(child, "%[exit 130%]") ~= nil, true) -- the command died, not the session
  H.run(child, H.rowof(child, "echo %$X"))
  eq(H.rowof(child, "^kept$") ~= nil, true)
end

T["<C-c> interrupts a routed python session; its globals survive"] = function()
  H.bootstrap(child, { name = "rp.bsh", lines = {
    "```python loc@x%%", "z = 41", "```", "",
    "```python loc@x%%", "import time; time.sleep(20)", "```", "",
    "```python loc@x%%", "print(z + 1)", "```" } })
  child.lua("require('bsh').transports.loc = { 'sh', '-c', '{cmd}' }")
  H.run(child, 2)
  start(H.rowof(child, "time.sleep"))
  eq(bufeval(child, "require('bsh.session').interrupt_session(b, 'python', 'loc@x')"), true)
  wait_for("KeyboardInterrupt")
  eq(H.rowof(child, "KeyboardInterrupt") ~= nil, true)
  H.run(child, H.rowof(child, "print%(z %+ 1%)"))
  eq(H.rowof(child, "^42$") ~= nil, true)
end

T["interrupt_session is false when idle, list/reset_all track sessions"] = function()
  H.bootstrap(child, { name = "i.bsh", lines = { "%% true" } })
  H.run(child, H.rowof(child, "^%%%% true$"))
  -- the session exists but is idle -> nothing to interrupt
  eq(bufeval(child, "require('bsh.session').interrupt_session(b, 'sh', '')"), false)
  eq(bufeval(child, "#require('bsh.session').list_sessions(b)"), 1)
  eq(bufeval(child, "require('bsh.session').reset_all(b)"), 1)
  eq(bufeval(child, "#require('bsh.session').list_sessions(b)"), 0)
end

T["a session that can't start, or exits, says so instead of running forever"] = function()
  H.bootstrap(child, { name = "dead.bsh", lines = {
    "```python %%", "print(1)", "```", "", "%% exit 7", "", "%% echo after" } })
  child.lua("require('bsh').python = 'no-such-python-xyz'")
  H.run(child, 2)
  eq(H.rowof(child, "running") == nil, true)
  eq(H.rowof(child, "^%[can't start a python session: `no%-such%-python%-xyz` not found%]$") ~= nil, true)
  H.run(child, H.rowof(child, "exit 7"))
  eq(H.rowof(child, "%[session exited 7%]") ~= nil, true)
  H.run(child, H.rowof(child, "echo after")) -- the next %% starts a fresh shell
  eq(H.rowof(child, "^after$") ~= nil, true)
end

return T
