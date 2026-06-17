-- Shared helpers for the bsh test suite. Each test file owns a child Neovim;
-- these wrap the common "set up a lab buffer, run a cell, read it back" dance so
-- the specs read like the behaviour they assert.
local M = {}

function M.child()
  return MiniTest.new_child_neovim()
end

-- A new_set whose hooks restart/stop the given child around each case (fresh
-- state per test).
function M.set(child)
  return MiniTest.new_set({
    hooks = {
      pre_case = function()
        child.restart({ "-u", "tests/minimal_init.lua" })
      end,
      post_once = child.stop,
    },
  })
end

-- Boot bsh in the child and load `opts.lines` into a fresh lab buffer.
-- opts: { lines, home (=$BSH_HOME, defaults to examples/bsh-home), name, noconfirm }
function M.bootstrap(child, opts)
  child.lua(
    [[
    local opts = ...
    _G.ROOT = vim.fn.fnamemodify(vim.api.nvim_get_runtime_file('lua/bsh/init.lua', false)[1], ':h:h:h')
    vim.env.BSH_HOME = opts.home or (_G.ROOT .. '/examples/bsh-home')
    _G.B = require('bsh'); B.config()
    if opts.noconfirm then B.confirm = function() return true end end
    vim.cmd('enew')
    if opts.name then vim.api.nvim_buf_set_name(0, opts.name) end
    vim.api.nvim_buf_set_lines(0, 0, -1, false, opts.lines or {})
    B.attach(0)
  ]],
    { opts or {} }
  )
end

-- Press <CR> (or g<CR>, the side-buffer gesture, when to_buf) on `row`, then let
-- the child's loop drain the async job.
function M.run(child, row, to_buf)
  child.lua(
    [[
    local row, to_buf = ...
    vim.api.nvim_win_set_cursor(0, { row, 0 })
    local key = to_buf and 'g<CR>' or '<CR>'
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), 'x', false)
    vim.wait(1500)
  ]],
    { row, to_buf or false }
  )
end

function M.lines(child)
  return child.lua_get("vim.api.nvim_buf_get_lines(0, 0, -1, false)")
end

-- 1-indexed row of the first line matching the Lua pattern `pat` (or nil).
function M.rowof(child, pat)
  return child.lua_get(
    [[(function(p)
      for i, l in ipairs(vim.api.nvim_buf_get_lines(0,0,-1,false)) do
        if l:match(p) then return i end
      end
    end)(...)]],
    { pat }
  )
end

return M
