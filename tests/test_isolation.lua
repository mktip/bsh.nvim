-- The suite itself must not write the user's real history, and an unwritable
-- history dir must not stop a cell from running.
local H = require("tests.helpers")
local eq = MiniTest.expect.equality
local child = H.child()
local T = H.set(child)

T["tests use a scratch history dir"] = function()
  H.bootstrap(child)
  local d = child.lua_get("require('bsh.config').history_dir")
  eq(type(d), "string")
  eq(vim.startswith(d, child.lua_get("vim.fn.stdpath('state')")), false)
end

T["an unwritable history dir doesn't stop a % cell"] = function()
  H.bootstrap(child, { lines = { "% echo still runs" } })
  child.lua([[require('bsh').setup({ history_dir = '/proc/no/such/dir' })]])
  H.run(child, 1)
  eq(H.lines(child), { "% echo still runs", "```out", "still runs", "```" })
end

return T
