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

-- wait until the status note on the first cell contains `text`
local function note_says(text)
  return child.lua_get([[(function(t) return vim.wait(4000, function()
    local m = vim.api.nvim_buf_get_extmarks(0, require('bsh.status').ns, 0, -1, { details = true })[1]
    return m ~= nil and m[4].virt_text ~= nil and m[4].virt_text[1][1]:find(t, 1, true) ~= nil
  end, 10) end)(...)]], { text })
end

T["a long cell shows running…, a session cell is timed too"] = function()
  local gate = vim.fn.tempname() -- the cell runs until the test lets it go
  H.bootstrap(child, { lines = { "%% while [ ! -e " .. gate .. " ]; do sleep 0.02; done; echo done" } })
  H.press(child, 1)
  eq(note_says("running 1s…"), true)
  vim.fn.writefile({}, gate)
  eq(note_says("· ok"), true)
  eq(notes()[1][2]:match("^  1%.%ds · ok$") ~= nil, true)
  vim.fn.delete(gate)
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
