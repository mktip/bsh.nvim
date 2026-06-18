-- Optional otter.nvim integration: real LSP -- completion, hover, go-to-def,
-- diagnostics -- INSIDE ```python fences. bsh has NO hard dependency on otter;
-- every call here is pcall-guarded, so the plugin behaves identically without it.
--
-- How otter works: it finds embedded code via the host buffer's treesitter
-- *injections* query, mirrors each chunk into a hidden per-language buffer, and
-- attaches a language server to that buffer (so your normal pyright/ruff run on
-- it). bsh fences are markdown code fences:
--   * `*.bsh.md` buffers are already `markdown` -- their injections query
--     captures ```lang fences, so otter works with no extra setup.
--   * the dedicated `bsh` filetype has no parser of its own, so we point
--     treesitter at the `markdown` parser for it (idempotent, global, harmless --
--     bsh's own engine is line-based and never touches treesitter). That also
--     gives bsh buffers free syntax highlighting of their fenced code.
local config = require("bsh.config")

local M = {}

-- Map the `bsh` filetype onto the markdown treesitter parser, once.
local registered = false
local function ensure_markdown_parser(buf)
  if not registered then
    registered = true
    pcall(vim.treesitter.language.register, "markdown", "bsh")
  end
  -- Start highlighting for THIS buffer too: the parser is now resolvable, and
  -- this both highlights the fenced code and warms the parse otter will read.
  pcall(vim.treesitter.start, buf)
end

-- Resolve config.otter -> (on?, loud?). loud = warn when otter is missing.
local function wanted()
  local opt = config.otter
  if opt == false then return false, false end
  return true, opt == true
end

local warned = false

-- Wire otter for `buf` if enabled and otter.nvim is available. Idempotent: otter
-- itself no-ops a re-activate, and the parser registration is guarded above.
function M.activate(buf)
  local on, loud = wanted()
  if not on then return end

  -- Only the markdown-fence filetypes bsh attaches to. `.bsh.typ` (typst) is
  -- skipped: typst has no ```lang fences for otter's injections to find.
  local ft = vim.bo[buf].filetype
  if ft ~= "bsh" and ft ~= "markdown" then return end

  local ok, otter = pcall(require, "otter")
  if not ok then
    if loud and not warned then
      warned = true
      vim.notify("bsh: config.otter is enabled but otter.nvim is not installed",
        vim.log.levels.WARN)
    end
    return
  end

  if ft == "bsh" then ensure_markdown_parser(buf) end

  -- activate(languages, completion, diagnostics, tsquery). A nil tsquery makes
  -- otter use the host filetype's injections query (markdown), which captures
  -- the ```python fences. Completion flows through your existing cmp `nvim_lsp`
  -- source -- otter registers as a language server client on the buffer.
  pcall(vim.api.nvim_buf_call, buf, function()
    otter.activate(config.otter_languages, true, true, nil)
  end)
end

return M
