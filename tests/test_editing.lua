-- Working with cells as text: the output cap, the io/ao text objects, ]c/[c
-- motions, and insert-mode <M-CR> (run, then start the next cell).
local H = require("tests.helpers")
local eq = MiniTest.expect.equality
local child = H.child()
local T = H.set(child)

local function wait_done()
  child.lua([[
    local buf = vim.api.nvim_get_current_buf()
    vim.wait(5000, function()
      if next(require('bsh.fence').inflight[buf] or {}) then return false end
      for _, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
        if l:find('...running', 1, true) then return false end
      end
      return true
    end, 10)
  ]])
end

T["inline output stops at output_max_lines, the rest is counted"] = function()
  H.bootstrap(child, { lines = { "% seq 100000" } })
  child.lua("B.output_max_lines = 3")
  H.run(child, 1)
  eq(H.lines(child), {
    "% seq 100000", "```out", "1", "2", "3",
    "[... 99997 more lines not shown; g<CR> runs it into a side buffer]", "```",
  })
end

T["the cap keeps stderr and the exit code after the note"] = function()
  H.bootstrap(child, { lines = { "% seq 5; echo oops >&2; exit 3" } })
  child.lua("B.output_max_lines = 2")
  H.run(child, 1)
  eq(H.lines(child), {
    "% seq 5; echo oops >&2; exit 3", "```out", "1", "2",
    "[... 3 more lines not shown; g<CR> runs it into a side buffer]",
    "", "[stderr]", "oops", "[exit 3]", "```",
  })
end

T["output under the cap is untouched; false disables it"] = function()
  H.bootstrap(child, { lines = { "% seq 3", "", "% seq 5" } })
  child.lua("B.output_max_lines = 3")
  H.run(child, 1)
  child.lua("B.output_max_lines = false")
  H.run(child, 8)
  eq(H.lines(child), {
    "% seq 3", "```out", "1", "2", "3", "```", "",
    "% seq 5", "```out", "1", "2", "3", "4", "5", "```",
  })
end

T["session output is capped too"] = function()
  H.bootstrap(child, { lines = { "%% seq 10" } })
  child.lua("B.output_max_lines = 2")
  H.run(child, 1)
  eq(H.lines(child), {
    "%% seq 10", "```out", "1", "2",
    "[... 8 more lines not shown; g<CR> runs it into a side buffer]", "```",
  })
end

local DOC = {
  "intro prose",           -- 1
  "% echo a; echo b",      -- 2
  "```out",                -- 3
  "a",                     -- 4
  "b",                     -- 5
  "```",                   -- 6
  "",                      -- 7
  "```python %",           -- 8
  "print(1)",              -- 9
  "```",                   -- 10
  "> a question",          -- 11
  ": .",                   -- 12
  "demo.hello",            -- 13
  "```out",                -- 14
  "hi",                    -- 15
  "```",                   -- 16
  "TODO: not a cell",      -- 17
}

local function yank(row, keys)
  child.lua(([[
    vim.api.nvim_win_set_cursor(0, { %d, 0 })
    vim.cmd('normal %s')
  ]]):format(row, keys))
  return child.lua_get("vim.fn.getreg('\"', 1, true)")
end

T["yio / yao on the trigger, inside the body, and on a closed fold"] = function()
  H.bootstrap(child, { lines = DOC })
  eq(yank(2, "yio"), { "a", "b" })
  eq(yank(5, "yio"), { "a", "b" })
  eq(yank(6, "yao"), { "```out", "a", "b", "```" })
  child.lua("vim.cmd('normal! zx'); vim.cmd('3foldclose')")
  eq(yank(3, "yio"), { "a", "b" })
end

T["io does nothing outside an output fence"] = function()
  H.bootstrap(child, { lines = DOC })
  child.lua("vim.fn.setreg('\"', 'untouched')")
  eq(yank(1, "yio"), { "untouched" })
  eq(yank(9, "yio"), { "untouched" }) -- an input fence isn't output
end

T["dao deletes a cell's output, leaving the trigger"] = function()
  H.bootstrap(child, { lines = DOC })
  yank(2, "dao")
  eq(vim.list_slice(H.lines(child), 1, 3), { "intro prose", "% echo a; echo b", "" })
end

T["]c / [c walk the cells, skipping prose and fence bodies"] = function()
  H.bootstrap(child, { lines = DOC })
  local seen = {}
  child.lua("vim.api.nvim_win_set_cursor(0, { 1, 0 })")
  for _ = 1, 6 do
    child.lua("vim.cmd('normal ]c')")
    seen[#seen + 1] = child.lua_get("vim.fn.line('.')")
  end
  eq(seen, { 2, 8, 11, 12, 13, 13 })
  child.lua("vim.cmd('normal 2[c')")
  eq(child.lua_get("vim.fn.line('.')"), 11)
end

T["insert <M-CR> runs the cell and opens the next prompt below its output"] = function()
  H.bootstrap(child, { lines = { "user@nowhere-xyz%% x", "% echo hi" } })
  child.lua([[
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('A<M-CR>pwd', true, false, true), 'x', false)
  ]])
  wait_done()
  eq(vim.list_slice(H.lines(child), 2), { "% echo hi", "```out", "hi", "```", "", "% pwd" })
end

T["<M-CR> keeps a route + session prefix, and is a newline on prose"] = function()
  H.bootstrap(child, { lines = { "some prose", "%% echo hi" } })
  child.lua([[
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('A<M-CR>', true, false, true), 'x', false)
  ]])
  wait_done()
  eq(H.lines(child), { "some prose", "%% echo hi", "```out", "hi", "```", "", "%% " })
  child.lua([[
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('A<M-CR>x<Esc>', true, false, true), 'x', false)
  ]])
  eq(vim.list_slice(H.lines(child), 1, 2), { "some prose", "x" })
end

T["normal <M-CR> runs the cell and leaves you typing the next one"] = function()
  H.bootstrap(child, { lines = { "%% echo hi" } })
  child.lua([[
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<M-CR>pwd<Esc>', true, false, true), 'x', false)
  ]])
  wait_done()
  eq(H.lines(child), { "%% echo hi", "```out", "hi", "```", "", "%% pwd" })
end

T["normal <M-CR> on a multiline fence just runs it"] = function()
  H.bootstrap(child, { lines = { "```%", "echo hi", "```" } })
  child.lua([[
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<M-CR>', true, false, true), 'x', false)
  ]])
  wait_done()
  eq(H.lines(child), { "```%", "echo hi", "```", "```out", "hi", "```" })
  eq(child.lua_get("vim.fn.mode()"), "n")
end

return T
