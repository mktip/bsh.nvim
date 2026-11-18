-- Route-aware completion (bsh.complete) and the normal-mode <M-CR> new prompt.
local H = require("tests.helpers")
local eq = MiniTest.expect.equality
local child = H.child()
local T = H.set(child)

T["word_context"] = function()
  local C = require("bsh.complete")
  local function wc(s)
    local c = C.word_context(s); return { c.word, c.start, c.first }
  end
  eq(wc(""), { "", 0, true })
  eq(wc("gi"), { "gi", 0, true })
  eq(wc("ls /gp"), { "/gp", 3, false })
  eq(wc("cat x | gr"), { "gr", 8, true })
  eq(wc("sudo sy"), { "sy", 5, true })
  eq(wc("./ru"), { "./ru", 0, false }) -- a path, even in command position
  eq(wc("ls "), { "", 3, false })
end

T["line_context finds the route and the word"] = function()
  local C = require("bsh.complete")
  local c = C.line_context("me@host%% ls /gp", 16)
  eq({ c.target, c.session, c.word, c.start, c.first }, { "me@host", true, "/gp", 13, false })
  c = C.line_context("% ", 2) -- a bare prompt still completes (commands)
  eq({ c.target, c.word, c.first }, { "", "", true })
  eq(C.line_context("% ls", 1), nil) -- cursor inside the prefix
  eq(C.line_context("just prose", 10), nil)
  eq(C.line_context("> ask the agent", 15), nil)
end

T["local paths complete in the doc's directory, dirs marked"] = function()
  H.bootstrap(child, { lines = { "% ls lua/bsh/co" } })
  local words = child.lua([[
    vim.api.nvim_buf_set_name(0, _G.ROOT .. '/x.bsh')
    local C = require('bsh.complete')
    local ctx = C.context(0, 0, 15)
    local res
    C.candidates(ctx, function(r) res = r end)
    vim.wait(5000, function() return res ~= nil end)
    local w = {}
    for _, it in ipairs(res) do w[#w + 1] = it.word .. ':' .. it.kind end
    table.sort(w)
    return w
  ]])
  eq(words, { "lua/bsh/complete.lua:file", "lua/bsh/config.lua:file" })
end

T["commands complete from PATH"] = function()
  H.bootstrap(child, { lines = { "% l" } })
  local has_ls = child.lua([[
    local C = require('bsh.complete')
    local res
    C.candidates(C.context(0, 0, 3), function(r) res = r end)
    vim.wait(10000, function() return res ~= nil end)
    for _, it in ipairs(res) do if it.word == 'ls' then return true end end
    return false
  ]])
  eq(has_ls, true)
end

T["normal <M-CR> opens a new prompt below the output, without running"] = function()
  H.bootstrap(child, { lines = { "me@host%% echo hi", "```out", "hi", "```", "after" } })
  child.lua([[
    vim.api.nvim_win_set_cursor(0, { 3, 0 }) -- inside the output
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<M-CR>ls<Esc>', true, false, true), 'x', false)
  ]])
  eq(child.lua_get("vim.api.nvim_buf_get_lines(0, 0, -1, false)"),
    { "me@host%% echo hi", "```out", "hi", "```", "", "me@host%% ls", "after" })
end

T["normal <M-CR> off a cell opens a bare prompt"] = function()
  H.bootstrap(child, { lines = { "some notes" } })
  child.lua([[
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<M-CR>ls<Esc>', true, false, true), 'x', false)
  ]])
  eq(child.lua_get("vim.api.nvim_buf_get_lines(0, 0, -1, false)"), { "some notes", "% ls" })
end

return T
