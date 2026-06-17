-- Minimal init for the test harness: put bsh and vendored mini.nvim on the
-- runtimepath, then set up mini.test. Run with:
--   nvim --headless --noplugin -u tests/minimal_init.lua -c "lua MiniTest.run()"
-- (see the Makefile `test` target).
local root = vim.fn.fnamemodify(vim.fn.resolve(vim.fn.expand("<sfile>:p")), ":h:h")
vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(root .. "/deps/mini.nvim")
package.path = root .. "/?.lua;" .. package.path -- so `require('tests.helpers')` resolves
require("mini.test").setup()
