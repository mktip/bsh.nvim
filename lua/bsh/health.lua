-- :checkhealth bsh -- what's installed, and which optional features that enables.
local M = {}

function M.check()
  local h = vim.health
  local config = require("bsh.config")
  local function exe(name) return vim.fn.executable(name) == 1 end

  h.start("bsh: core")
  if vim.fn.has("nvim-0.10") == 1 then
    h.ok("Neovim " .. tostring(vim.version()))
  else
    h.error("Neovim 0.10+ is required")
  end
  if exe("sh") then h.ok("sh found") else h.error("no `sh` on $PATH: shell cells can't run") end
  if exe("ssh") then h.ok("ssh found (remote cells)") else h.warn("no `ssh`: remote cells won't work") end

  h.start("bsh: python cells")
  if exe(config.python) then
    h.ok(config.python .. " found")
  else
    h.warn("`" .. config.python .. "` not found: python cells won't run (see config.python)")
  end

  h.start("bsh: agent cells")
  local pi, llm = exe("pi"), exe("llm")
  local want = config.agent
  if want == "auto" then want = pi and "pi" or "llm" end
  if (want == "pi" and pi) or (want == "llm" and llm) then
    h.ok("using " .. want .. (config.agent == "auto" and " (agent = \"auto\")" or ""))
  else
    h.warn("`" .. want .. "` not found: `>` cells won't run. Install pi (https://pi.dev) or llm")
  end

  h.start("bsh: optional tools")
  if exe("fd") and exe("fzf") then
    h.ok("fd + fzf found (`: goto`)")
  else
    h.info("`: goto` needs fd and fzf (or your own `here` command)")
  end
  if pcall(require, "otter") then
    h.ok("otter.nvim found (LSP inside python fences)")
  else
    h.info("otter.nvim not installed (optional: LSP inside python fences)")
  end

  h.start("bsh: $BSH_HOME")
  local home = require("bsh.namespace").ns_home()
  if home ~= "" then
    h.ok("namespace root: " .. home)
  else
    h.info("no namespace root ($BSH_HOME unset and ~/.config/bsh missing): `name.space` cells are off")
  end
end

return M
