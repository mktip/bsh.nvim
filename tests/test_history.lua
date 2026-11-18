-- Per-route command history (bsh.history): recording, shell-history parsing,
-- <C-p>/<C-n> recall on a prompt line, and the :BshHistory buffer.
local H = require("tests.helpers")
local eq = MiniTest.expect.equality
local child = H.child()
local T = H.set(child)

T["parse_shell_history: bash stamps, zsh extended, fish"] = function()
  local h = require("bsh.history")
  eq(h.parse_shell_history({ "#1700000000", "ls -la", ": 1700000001:0;git status", "- cmd: make test", "ls -la   ",
    "  when: 1700000002", "echo multi \\", "" }), { "ls -la", "git status", "make test", "ls -la" })
end

-- boot with a private history dir and no shell history (deterministic)
local function boot(lines)
  H.bootstrap(child, { lines = lines })
  child.lua([[
    local d = vim.fn.tempname()
    require('bsh').setup({ history_dir = d, history_shell = false })
  ]])
end

local function keys(k)
  child.lua("vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(..., true, false, true), 'x', false)", { k })
end

T["running a cell records it per route, newest first, aliases shared"] = function()
  boot({})
  local own = child.lua([[
    local h = require('bsh.history')
    require('bsh').setup({ routes = { box = 'me@server' } })
    h.add('', 'ls'); h.add('me@server', 'squeue'); h.add('box', 'sinfo'); h.add('', 'pwd'); h.add('', 'ls')
    return { h.own(''), h.own('me@server') }
  ]])
  eq(own, { { "ls", "pwd" }, { "sinfo", "squeue" } })
end

T["<C-p>/<C-n> walk the route's history, filtered by what's typed"] = function()
  boot({ "% git" })
  child.lua([[
    local h = require('bsh.history')
    for _, c in ipairs({ 'git log', 'ls', 'git status', 'git diff' }) do h.add('', c) end
    h.add('me@host', 'git remote-only')
  ]])
  child.lua("vim.api.nvim_win_set_cursor(0, { 1, 0 })")
  keys("A<C-p><C-p><Esc>")
  eq(H.lines(child), { "% git status" })          -- newest git* first, then older
  child.lua("vim.api.nvim_buf_set_lines(0, 0, -1, false, { '% git' })")
  keys("A<C-p><C-p><C-n><Esc>")
  eq(H.lines(child), { "% git diff" })
  child.lua("vim.api.nvim_buf_set_lines(0, 0, -1, false, { '% git' })")
  keys("A<C-p><C-n><Esc>")
  eq(H.lines(child), { "% git" })                  -- back past the newest: what you typed
  child.lua("vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'me@host% ' })")
  keys("A<C-p><Esc>")
  eq(H.lines(child), { "me@host% git remote-only" }) -- a remote prompt walks ITS history
end

T["<C-p> off a prompt line is Vim's own"] = function()
  boot({ "alpha", "al" })
  child.lua("vim.api.nvim_win_set_cursor(0, { 2, 0 })")
  keys("A<C-p><Esc>")
  eq(H.lines(child), { "alpha", "alpha" }) -- keyword completion, untouched
end

T[":BshHistory opens the route's history; <CR> fills the prompt"] = function()
  boot({ "me@host% x" })
  child.lua([[
    local h = require('bsh.history')
    h.add('me@host', 'first'); h.add('me@host', 'second'); h.add('', 'local only')
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.cmd('BshHistory')
  ]])
  eq(H.lines(child), { "first", "second" }) -- oldest at the top, newest at the bottom
  eq(child.lua_get("vim.fn.line('.')"), 2)
  keys("k<CR><Esc>")
  eq(H.lines(child), { "me@host% first" })
end

return T
