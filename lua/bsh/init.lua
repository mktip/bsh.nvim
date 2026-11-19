-- bsh: a shell in a buffer, in the spirit of xiki and notebooks.
--
-- This is the front door, and it stays light: Neovim loads it at startup (from
-- plugin/bsh.lua, and from your setup()), so it only registers the filetype, the
-- autocommands and :Bsh, and holds your options. The engine (bsh.core) loads the
-- first time a bsh buffer is attached; anything else asked of `require('bsh')`
-- is forwarded to it.

local M = {}

local config = require("bsh.config")
local options = require("bsh.options")

local function core()
  return require("bsh.core")
end

function M.attach(buf)
  return core().attach(buf)
end

-- (kept for foldexpr settings made by older versions)
function M.foldexpr(lnum) return require("bsh.fence").foldexpr(lnum) end
function M.foldtext() return require("bsh.fence").foldtext() end

M.config = function()
  -- expose the run marker to child processes: a cell-emitting namespace command
  -- (exit 151) prints e.g. `<addr>%% ` and reads $BSH_MARKER for the symbol, so it
  -- stays in sync with config.marker instead of hardcoding `$`/`%`.
  vim.env.BSH_MARKER = config.marker

  -- `*.bsh` is the dedicated filetype; `*.bsh.md` / `*.bsh.markdown` stay
  -- markdown -- so they keep markdown highlighting -- but get buffer-shell
  -- powers via M.attach below.
  vim.filetype.add({
    extension = { bsh = "bsh" },
    pattern = {
      ["%.bsh%.md$"] = "markdown",
      ["%.bsh%.markdown$"] = "markdown",
    },
  })

  local group = vim.api.nvim_create_augroup("bsh", { clear = true })
  -- attach on the dedicated filetype...
  vim.api.nvim_create_autocmd("FileType", {
    group = group, pattern = "bsh",
    callback = function(args) M.attach(args.buf) end,
  })
  -- ...and on the `*.bsh.md` markdown convention (filename, not filetype, since
  -- the compound-filetype FileType event we can't rely on never enters into it).
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
    group = group, pattern = { "*.bsh.md", "*.bsh.markdown" },
    callback = function(args) M.attach(args.buf) end,
  })
  -- files at the end of a route open as bsh://<route>:<path> buffers
  vim.api.nvim_create_autocmd("BufReadCmd", {
    group = group, pattern = "bsh://*:*",
    callback = function(args) require("bsh.remote").read(args.buf) end,
  })
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = group, pattern = "bsh://*:*",
    callback = function(args) require("bsh.remote").write(args.buf) end,
  })

  -- :Bsh  -> scratch lab buffer to play in.
  -- :Bsh! -> attach lab powers to the CURRENT buffer in place (any filetype),
  --             so an existing markdown/notes file becomes runnable on demand.
  vim.api.nvim_create_user_command("Bsh", function(o)
    if o.bang then
      M.attach(0)
    else
      vim.cmd("enew")
      vim.bo.filetype = "bsh"
      vim.bo.bufhidden = "hide"
    end
  end, { bang = true, desc = "open a scratch bsh buffer (! = attach to current)" })
end

-- require("bsh").setup({ marker = "%", agent = "llm", ... }): merge options into
-- bsh.config. The plugin already wires itself up from plugin/bsh.lua, so this
-- only sets options (and is what lazy.nvim's `config = true` / `opts = {}` call).
-- Table options (e.g. `transports`) are merged, so adding one keeps the defaults.
-- A name no default knows is kept until the engine loads (a rule's options are
-- declared by the rule) and warned about then.
function M.setup(opts)
  local unknown = false
  for k, v in pairs(opts or {}) do
    if not options.set(k, v) then unknown = true end
  end
  vim.env.BSH_MARKER = config.marker
  if unknown and package.loaded["bsh.core"] then options.warn_unknown() end
  return M
end

-- Public option surface: `require('bsh').python`, `…remote_login`, etc. proxy to
-- bsh.config, so reads and writes hit the single source of truth the engine
-- reads. Anything else (attach, the engine's functions) comes from bsh.core.
setmetatable(M, {
  __index = function(_, k)
    if config[k] ~= nil then return config[k] end
    return core()[k]
  end,
  __newindex = function(t, k, v)
    if config[k] ~= nil then config[k] = v else rawset(t, k, v) end
  end,
})

return M
