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

T["interrupt_session is false when idle, list/reset_all track sessions"] = function()
  H.bootstrap(child, { name = "i.bsh", lines = { "%% true" } })
  H.run(child, H.rowof(child, "^%%%% true$"))
  -- the session exists but is idle -> nothing to interrupt
  eq(bufeval(child, "require('bsh.session').interrupt_session(b, 'sh', '')"), false)
  eq(bufeval(child, "#require('bsh.session').list_sessions(b)"), 1)
  eq(bufeval(child, "require('bsh.session').reset_all(b)"), 1)
  eq(bufeval(child, "#require('bsh.session').list_sessions(b)"), 0)
end

return T
