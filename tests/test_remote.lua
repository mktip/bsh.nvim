-- Remote files: a file at the end of any route opens as a bsh://<route>:<path>
-- buffer, read with `cat` and written with `cat >` through that route. A fake
-- `loc` transport (plain local sh) stands in for ssh/docker, nested two deep.
local H = require("tests.helpers")
local eq = MiniTest.expect.equality
local child = H.child()
local T = H.set(child)

local function setup()
  H.bootstrap(child)
  child.lua([[
    require('bsh').setup({ transports = { loc = { "sh", "-c", "{cmd}" } } })
    _G.DIR = vim.fn.tempname(); vim.fn.mkdir(DIR, 'p')
    vim.fn.writefile({ 'print("hi")', 'x = 1' }, DIR .. '/a.py')
    _G.ROUTE = 'loc@outer/loc@inner' -- a container in a host, say
  ]])
end

T["a file over a nested route opens, with its filetype"] = function()
  setup()
  child.lua("require('bsh.remote').open(ROUTE, DIR .. '/a.py')")
  eq(H.lines(child), { 'print("hi")', "x = 1" })
  eq(child.lua_get("vim.bo.filetype"), "python")
  eq(child.lua_get("vim.bo.modified"), false)
  eq(child.lua_get("vim.api.nvim_buf_get_name(0)"),
    child.lua_get("'bsh://' .. ROUTE .. ':' .. DIR .. '/a.py'"))
end

T[":w writes it back through the route"] = function()
  setup()
  child.lua([[
    require('bsh.remote').open(ROUTE, DIR .. '/a.py')
    vim.api.nvim_buf_set_lines(0, 1, 2, false, { "x = 2", "y = 'it''s'" })
    vim.cmd('silent write')
  ]])
  eq(child.lua_get("vim.fn.readfile(DIR .. '/a.py')"), { 'print("hi")', "x = 2", "y = 'it''s'" })
  eq(child.lua_get("vim.bo.modified"), false)
end

T["a missing file is a new buffer, created on :w"] = function()
  setup()
  child.lua([[
    require('bsh.remote').open(ROUTE, DIR .. '/new.txt')
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "fresh" })
    vim.cmd('silent write')
  ]])
  eq(child.lua_get("vim.fn.readfile(DIR .. '/new.txt')"), { "fresh" })
end

T["<CR> on a file in a routed listing opens it remotely"] = function()
  setup()
  child.lua([[vim.api.nvim_buf_set_lines(0, 0, -1, false, { ROUTE .. ': ' .. DIR })]])
  H.run(child, 1)
  local row = H.rowof(child, "^a%.py$")
  H.run(child, row)
  eq(child.lua_get("vim.api.nvim_buf_get_name(0)"),
    child.lua_get("'bsh://' .. ROUTE .. ':' .. DIR .. '/a.py'"))
  eq(H.lines(child), { 'print("hi")', "x = 1" })
end

return T
