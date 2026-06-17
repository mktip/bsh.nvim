-- `bin/bsh` — the PATH dispatcher: resolves a dotted name under $BSH_HOME (same
-- rules as the editor) and execs it in the CALLER's $PWD. These shell out to the
-- real script via vim.fn.system, so they exercise the actual resolution + exec.
local H = require("tests.helpers")
local eq = MiniTest.expect.equality
local child = H.child()
local T = H.set(child)

-- run a command line; return (stdout, exit_code) in one round-trip.
local function run(cmd)
  local r = child.lua_get(
    "(function(c) local o = vim.fn.system(c); return { o, vim.v.shell_error } end)(...)",
    { cmd }
  )
  return r[1], r[2]
end
local function bsh() -- absolute path to the script under test (BSH_HOME = examples/bsh-home)
  return child.lua_get("_G.ROOT") .. "/bin/bsh"
end

T["resolves a dotted name and runs it (shebang dispatch)"] = function()
  H.bootstrap(child, {}) -- sets vim.env.BSH_HOME = examples/bsh-home (inherited by system())
  local out, code = run(bsh() .. " demo.hello")
  eq(code, 0)
  eq(out:match("hello from demo%.hello") ~= nil, true)
end

T["forwards args (nested leaf)"] = function()
  H.bootstrap(child, {})
  local out = run(bsh() .. " llm.tools.reverse 'abc def'")
  eq(out:match("fed cba") ~= nil, true) -- reverse of "abc def"
end

T["runs in the CALLER's cwd, not the doc dir"] = function()
  H.bootstrap(child, {})
  -- a throwaway $BSH_HOME with a leaf that just prints where it ran
  local home = child.lua_get("vim.fn.tempname()")
  child.lua(
    [[
    local home = ...
    vim.fn.mkdir(home, 'p')
    local p = home .. '/where.sh'
    vim.fn.writefile({ '#!/bin/sh', 'pwd' }, p)
    vim.fn.setfperm(p, 'rwxr-xr-x')
  ]],
    { home }
  )
  local out, code = run("cd /tmp && BSH_HOME=" .. home .. " " .. bsh() .. " where")
  eq(code, 0)
  eq(out:match("^/tmp") ~= nil, true) -- ran in /tmp, the caller's cwd
end

T["a directory runs its .enter"] = function()
  H.bootstrap(child, {})
  local out, code = run(bsh() .. " host") -- examples/bsh-home/host/.enter
  eq(code, 0)
  eq(out:match("host:") ~= nil, true)
end

T["an unresolved name errors with 127"] = function()
  H.bootstrap(child, {})
  local _, code = run(bsh() .. " nope.zzz")
  eq(code, 127)
end

return T
