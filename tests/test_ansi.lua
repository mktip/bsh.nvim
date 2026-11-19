-- ANSI escapes: clean text in the buffer, colours as highlights.
local H = require("tests.helpers")
local eq = MiniTest.expect.equality
local child = H.child()
local T = H.set(child)

T["parse: SGR -> spans, everything else dropped, tabs kept"] = function()
  local ansi = require("bsh.ansi")
  local E = string.char(27)
  local text, spans = ansi.parse(E .. "[1;31mred" .. E .. "[0m plain\tx")
  eq(text, "red plain\tx")
  eq(#spans, 1)
  eq({ spans[1][1], spans[1][2] }, { 0, 3 })
  -- 256-colour fg + bg, a hyperlink (OSC 8), cursor moves, charset select
  text, spans = ansi.parse(E .. "[38;5;252m" .. E .. "[48;5;235m gpfs" .. E .. "[0m "
    .. E .. "]8;;https://x" .. E .. "\\link" .. E .. "]8;;" .. E .. "\\" .. E .. "[2J" .. E .. "(B!")
  eq(text, " gpfs link!")
  eq({ spans[1][1], spans[1][2] }, { 0, 5 })
  -- a style left on carries to the next line (terminal semantics)
  local st = {}
  ansi.parse(E .. "[32mgreen...", st)
  local _, s2 = ansi.parse("still green", st)
  eq({ s2[1][1], s2[1][2] }, { 0, 11 })
end

T["a cell's colours are highlights over clean text"] = function()
  H.bootstrap(child, { lines = { [[% printf '\033[1;31mERR\033[0m ok\n']] } })
  H.run(child, 1)
  eq(H.lines(child), { [[% printf '\033[1;31mERR\033[0m ok\n']], "```out", "ERR ok", "```" })
  local marks = child.lua_get([[vim.tbl_map(function(m) return { m[2], m[3], m[4].end_col, m[4].hl_group } end,
    vim.api.nvim_buf_get_extmarks(0, require('bsh.ansi').ns, 0, -1, { details = true }))]])
  eq(#marks, 1)
  eq({ marks[1][1], marks[1][2], marks[1][3] }, { 2, 0, 3 })
  eq(child.lua_get("vim.api.nvim_get_hl(0, { name = ... }).bold", { marks[1][4] }), true)
end

T["ansi = 'strip' cleans without colour; false keeps the raw codes"] = function()
  H.bootstrap(child, { lines = { [[% printf '\033[32mgo\033[0m\n']] } })
  child.lua("require('bsh').setup({ ansi = 'strip' })")
  H.run(child, 1)
  eq(H.lines(child)[3], "go")
  eq(child.lua_get("#vim.api.nvim_buf_get_extmarks(0, require('bsh.ansi').ns, 0, -1, {})"), 0)
  child.lua("require('bsh').setup({ ansi = false })")
  H.run(child, 1)
  eq(H.lines(child)[3], string.char(27) .. "[32mgo" .. string.char(27) .. "[0m")
end

return T
