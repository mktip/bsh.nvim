-- bsh.nvim auto-setup: registers the filetype, autocommands and :Bsh command.
-- Runs once. Set `vim.g.loaded_bsh = 1` before this loads to opt out and call
-- `require("bsh").config()` yourself.
if vim.g.loaded_bsh then
  return
end
vim.g.loaded_bsh = 1

require("bsh").config()
