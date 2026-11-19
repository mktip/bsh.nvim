-- `%` one-shot shell cells + folding behaviour. (`%` is config.marker's default.)
local H = require("tests.helpers")
local eq = MiniTest.expect.equality
local child = H.child()
local T = H.set(child)

T["% runs into an owned out fence"] = function()
  H.bootstrap(child, { lines = { "% echo hello" } })
  H.run(child, 1)
  eq(H.lines(child), { "% echo hello", "```out", "hello", "```" })
end

T["% is a real shell: pipes work"] = function()
  H.bootstrap(child, { lines = { "% seq 3 | tac" } })
  H.run(child, 1)
  eq(H.lines(child), { "% seq 3 | tac", "```out", "3", "2", "1", "```" })
end

T["re-running replaces the fence body (idempotent)"] = function()
  H.bootstrap(child, { lines = { "% echo one" } })
  H.run(child, 1)
  child.lua("vim.api.nvim_buf_set_lines(0, 0, 1, false, { '% echo two' })")
  H.run(child, 1)
  eq(H.lines(child), { "% echo two", "```out", "two", "```" })
end

T["adjacent input+output fences are SEPARATE folds"] = function()
  H.bootstrap(child, {
    lines = { "```%", "echo hi", "```", "```out", "hi", "```" },
  })
  child.lua([[
    vim.wo.foldmethod = 'expr'
    vim.wo.foldexpr = "v:lua.require'bsh'.foldexpr(v:lnum)"
    vim.cmd('normal! zx')
  ]])
  -- the input fence (lines 1-3) and output fence (4-6) must close independently
  eq(child.lua_get("vim.fn.foldclosedend(1)"), -1) -- open by default (foldlevel 99)
  child.lua("vim.cmd('1foldclose')")
  eq(child.lua_get("vim.fn.foldclosedend(1)"), 3)
  child.lua("vim.cmd('4foldclose')")
  eq(child.lua_get("vim.fn.foldclosedend(4)"), 6)
end

T["output can't close its own fence (``` is neutralised), one-shot and session"] = function()
  local bt = string.rep(string.char(96), 3)
  local one = [[% printf 'a\n\140\140\140\nb\n']]
  local sess = [[%% printf 'c\n\140\140\140x\n']]
  H.bootstrap(child, { lines = { one, "", sess, "after" } })
  H.run(child, 3)
  H.run(child, 1)
  eq(H.lines(child), { one, bt .. "out", "a", "'''", "b", bt, "",
    sess, bt .. "out", "c", "'''x", bt, "after" })
end

return T
