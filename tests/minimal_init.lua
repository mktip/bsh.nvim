-- Minimal init for the test harness: put bsh and vendored mini.nvim on the
-- runtimepath, then set up mini.test. Run with:
--   nvim --headless --noplugin -u tests/minimal_init.lua -c "lua MiniTest.run()"
-- (see the Makefile `test` target).
local root = vim.fn.fnamemodify(vim.fn.resolve(vim.fn.expand("<sfile>:p")), ":h:h")
vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(root .. "/deps/mini.nvim")
package.path = root .. "/?.lua;" .. package.path -- so `require('tests.helpers')` resolves
require("mini.test").setup()

-- Never touch the real history (stdpath("state")/bsh/history) or read the
-- machine's shell history: each Neovim the suite starts gets a scratch dir.
local cfg = require("bsh.config")
cfg.history_dir = vim.fn.tempname() .. "-bsh-history"
cfg.history_shell = false
