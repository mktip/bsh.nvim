-- setup(): options are checked, a rule's options can be set before the engine
-- (which declares them) has loaded, and startup loads only the front door.
local H = require("tests.helpers")
local eq = MiniTest.expect.equality
local child = H.child()
local T = H.set(child)

local function capture()
  child.lua("_G.msgs = {}; vim.notify = function(m) table.insert(_G.msgs, m) end")
end

T["startup loads only the front door; the engine comes with the first bsh buffer"] = function()
  child.lua("vim.cmd('runtime plugin/bsh.lua')")
  eq(child.lua_get("package.loaded['bsh.core'] == nil"), true)
  eq(child.lua_get("package.loaded['bsh.job'] == nil"), true)
  child.lua("vim.cmd('edit ' .. vim.fn.tempname() .. '.bsh.md')")
  eq(child.lua_get("package.loaded['bsh.core'] ~= nil"), true)
  eq(child.lua_get("vim.b.bsh_attached"), true)
end

T["an agent option set before the engine loads is kept; a typo is warned about then"] = function()
  capture()
  child.lua("require('bsh').setup({ agent_model = 'default', agent_show_thinking = false, agnet = 'pi' })")
  eq(child.lua_get("_G.msgs"), {}) -- can't tell a typo from a rule's option yet
  child.lua("vim.cmd('runtime plugin/bsh.lua'); vim.cmd('edit ' .. vim.fn.tempname() .. '.bsh')")
  eq(child.lua_get("{ require('bsh.config').agent_model, require('bsh.config').agent_show_thinking }"),
    { "default", false })
  eq(child.lua_get("_G.msgs"), { "bsh: unknown option 'agnet'" })
  -- with the engine up, an unknown name is warned about at once
  child.lua("require('bsh').setup({ histroy = false })")
  eq(child.lua_get("_G.msgs[2]"), "bsh: unknown option 'histroy'")
end

T["a value of the wrong type is refused with a warning; false always turns off"] = function()
  capture()
  child.lua([[require('bsh').setup({ marker = true, output_max_lines = "lots", history_max = 10,
    otter = true, remote_login = false, history_dir = "/tmp/h" })]])
  local msgs = child.lua_get("_G.msgs")
  eq(#msgs, 2)
  eq(msgs[1]:match("option '(%S+)' should be a (%a+)") ~= nil, true)
  local cfg = child.lua_get("{ require('bsh.config').marker, require('bsh.config').output_max_lines, "
    .. "require('bsh.config').history_max, require('bsh.config').otter, require('bsh.config').remote_login, "
    .. "require('bsh.config').history_dir }")
  eq(cfg, { "%", 2000, 10, true, false, "/tmp/h" })
end

return T
