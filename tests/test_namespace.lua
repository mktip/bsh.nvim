-- `$BSH_HOME` namespace cells: run, args, peek, drill, scaffold, tag-change.
local H = require("tests.helpers")
local eq = MiniTest.expect.equality
local child = H.child()
local T = H.set(child)

T["a leaf runs by shebang into an out fence"] = function()
  H.bootstrap(child, { lines = { "llm.tools.weather" } })
  H.run(child, 1)
  eq(H.lines(child), { "llm.tools.weather", "```out", "Istanbul: partly cloudy, 21°C, wind 12 km/h", "```" })
end

T["inline args reach the leaf"] = function()
  H.bootstrap(child, { lines = { "llm.tools.reverse hello" } })
  H.run(child, 1)
  eq(H.lines(child), { "llm.tools.reverse hello", "```out", "olleh", "```" })
end

T["args go through the shell (sub-shell expansion)"] = function()
  H.bootstrap(child, { lines = { 'llm.tools.reverse "$(echo abc)"' } })
  H.run(child, 1)
  eq(H.lines(child), { 'llm.tools.reverse "$(echo abc)"', "```out", "cba", "```" })
end

T["a dir with .enter runs it; trailing dot lists instead"] = function()
  H.bootstrap(child, { lines = { "demo.greet" } })
  H.run(child, 1)
  eq(H.lines(child), { "demo.greet", "```out", "greetings from the demo.greet namespace folder", "```" })

  child.lua("vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'demo.greet.' })")
  H.run(child, 1)
  eq(H.lines(child), { "demo.greet.", "```dir", "../", ".enter", "```" })
end

T["plain dir canonicalises to a trailing-dot listing"] = function()
  H.bootstrap(child, { lines = { "demo" } })
  H.run(child, 1)
  eq(H.lines(child), { "demo.", "```dir", "../", "greet/", "hello.sh", "```" })
end

T["drilling a namespace listing stays dotted (no double dot)"] = function()
  H.bootstrap(child, { lines = { "llm." } })
  H.run(child, 1)
  H.run(child, H.rowof(child, "tools/")) -- drill into tools/
  eq(H.lines(child), { "llm.tools.", "```dir", "../", "reverse.py", "weather.py", "```" })
end

T["tag change replaces the old fence (no orphan)"] = function()
  H.bootstrap(child, { lines = { "llm.tools.reverse hi" } })
  H.run(child, 1)
  child.lua("vim.api.nvim_buf_set_lines(0, 0, 1, false, { 'llm.tools' })")
  H.run(child, 1)
  eq(H.lines(child), { "llm.tools.", "```dir", "../", "reverse.py", "weather.py", "```" })
end

T["foo.bar! scaffolds an executable leaf, then it runs"] = function()
  local home = child.lua_get("vim.fn.tempname()")
  child.lua("vim.fn.mkdir(... , 'p')", { home })
  H.bootstrap(child, { lines = { "demo.newcmd!" }, home = home, noconfirm = true })
  H.run(child, 1)
  eq(child.lua_get("vim.fn.executable(... .. '/demo/newcmd.sh')", { home }), 1)
  -- now invoke it
  child.lua("vim.cmd('enew'); vim.api.nvim_buf_set_lines(0,0,-1,false,{'demo.newcmd world'}); require('bsh').attach(0)")
  H.run(child, 1)
  eq(H.lines(child), { "demo.newcmd world", "```out", "hello from demo.newcmd world", "```" })
end

return T
