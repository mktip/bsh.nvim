-- Elapsed time / exit status as virtual text on the trigger line.
local H = require("tests.helpers")
local eq = MiniTest.expect.equality
local child = H.child()
local T = H.set(child)

local function notes()
  return child.lua_get([[vim.tbl_map(function(m) return { m[2], m[4].virt_text and m[4].virt_text[1][1] or "" } end,
    vim.api.nvim_buf_get_extmarks(0, require('bsh.status').ns, 0, -1, { details = true }))]])
end

T["a one-shot shows its time and exit; a failure says so"] = function()
  H.bootstrap(child, { lines = { "% true", "", "% exit 3" } })
  H.run(child, 3)
  H.run(child, 1)
  local n = notes()
  eq(#n, 2)
  eq(n[1][1], 0)
  eq(n[1][2]:match("^  %d+%.%ds · ok$") ~= nil, true)
  eq(n[2][2]:match("· exit 3$") ~= nil, true)
  eq(H.lines(child)[1], "% true") -- nothing written into the text
end

T["a long cell shows running…, a session cell is timed too"] = function()
  H.bootstrap(child, { lines = { "%% sleep 1.6; echo done" } })
  child.lua([[
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<CR>', true, false, true), 'x', false)
    vim.wait(1300)
  ]])
  eq(notes()[1][2]:match("running 1s…") ~= nil, true)
  child.lua("vim.wait(3000, function() return vim.api.nvim_buf_get_lines(0, 2, 3, false)[1] == 'done' end)")
  child.lua("vim.wait(100)")
  eq(notes()[1][2]:match("^  1%.%ds · ok$") ~= nil, true)
end

T["a quick listing stays quiet; status = false turns it off"] = function()
  H.bootstrap(child, { lines = { ": .", "", "% true" } })
  H.run(child, 1)
  eq(#notes(), 0)
  child.lua("require('bsh').setup({ status = false })")
  H.run(child, H.rowof(child, "^%% true$"))
  eq(#notes(), 0)
end

return T
