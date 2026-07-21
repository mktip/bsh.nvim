-- Minimal, self-contained Neovim config used ONLY for recording the VHS demo.
-- Keeps the recording reproducible and free of any personal config. Launch with:
--   nvim --clean -u assets/vhs/init.lua assets/vhs/demo.bsh
-- (--clean skips your user config; -u loads this one instead.)

-- This file lives at <repo>/assets/vhs/init.lua, so the plugin root is three
-- path segments up. Use `:p` (absolutize against cwd) rather than resolve() --
-- resolve() follows/mangles symlinks and, on a relative `-u` path, produced a
-- bogus root, which left BSH_HOME invalid and silently broke namespace cells.
local src = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(src, ":p:h:h:h")
vim.opt.runtimepath:prepend(root)

-- $BSH_HOME lets bare `name.space` cells (e.g. `demo.reverse`) resolve to the
-- example scripts shipped in the repo. PIN it to this checkout -- do NOT defer to
-- an inherited env var, which may point at a different (or non-existent) tree and
-- would make namespace cells silently fall through to prose.
vim.env.BSH_HOME = root .. "/examples/bsh-home"

vim.g.mapleader = " "
vim.g.maplocalleader = ","

vim.o.termguicolors = true
vim.o.background = "dark"
vim.o.swapfile = false -- no swap: recording reopens demo.bsh repeatedly
vim.o.number = false
vim.o.signcolumn = "no"
vim.o.laststatus = 0
vim.o.cmdheight = 1
vim.o.showmode = false
vim.o.scrolloff = 4
vim.o.fillchars = "eob: "
pcall(vim.cmd.colorscheme, "habamax")

-- We type cells live in the recording; keep indentation literal so `o` + typing
-- never smart-indents a `%`/fence line out from under the cursor.
vim.o.autoindent = false
vim.api.nvim_create_autocmd("FileType", {
  pattern = "bsh",
  callback = function(a)
    vim.bo[a.buf].autoindent = false
    vim.bo[a.buf].indentexpr = ""
    -- don't auto-continue comment leaders when typing `o`/<CR> after a `# ...` line
    vim.bo[a.buf].formatoptions = (vim.bo[a.buf].formatoptions:gsub("[cro]", ""))
  end,
})

-- plugin/bsh.lua auto-loads off runtimepath and attaches to *.bsh buffers.
