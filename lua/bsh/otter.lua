-- Optional otter.nvim integration: real LSP -- completion, hover, go-to-def,
-- diagnostics -- INSIDE ```python fences. bsh has NO hard dependency on otter;
-- every call here is pcall-guarded, so the plugin behaves identically without it.
--
-- How otter works: it finds embedded code via the host buffer's treesitter
-- *injections* query, mirrors each chunk into a hidden per-language buffer, and
-- attaches a language server to that buffer (so your normal pyright/ruff run on
-- it). Crucially, otter resolves WHICH parser/injections query to use from the
-- host buffer's FILETYPE (`vim.treesitter.language.get_lang(ft)`), so the lever
-- we have is that filetype -> the `markdown` language. bsh fences are markdown
-- code fences:
--   * `*.bsh.md` buffers are already `markdown` -- their injections query
--     captures ```lang fences, so otter works with no extra setup.
--   * the dedicated `bsh` filetype (and any `:Bsh!`-attached prose/notes buffer
--     whose filetype has no parser of its own) we point at the `markdown` parser,
--     so otter resolves the same query. That registration is global-per-filetype
--     but only ever applied to filetypes WITHOUT a grammar (bsh, text, notes, …) --
--     never a real code filetype -- so it can't clobber e.g. python/lua buffers,
--     and it harmlessly gives those buffers free fence highlighting too.
local config = require("bsh.config")

local M = {}

-- Per-filetype cache: true = the ft has a grammar of its OWN (leave it alone), so
-- we never turn a real code file into markdown when `:Bsh!`-attaching it.
local owns_grammar = {}

-- Make `ft` resolve to the markdown TS language (so otter's filetype->parser
-- lookup finds markdown's injections query) and warm the parse on `buf`. Returns
-- false for a filetype with its own grammar (a real code file): bsh fences make no
-- sense there, so the caller skips otter.
local function map_to_markdown(buf, ft)
  if vim.treesitter.language.get_lang(ft) ~= "markdown" then
    if owns_grammar[ft] == nil then
      local lang = vim.treesitter.language.get_lang(ft) or ft
      local ok, added = pcall(vim.treesitter.language.add, lang)
      owns_grammar[ft] = ok and added ~= false
    end
    if owns_grammar[ft] then return false end
    pcall(vim.treesitter.language.register, "markdown", ft)
  end
  -- Start highlighting for THIS buffer too: the parser is now resolvable, and
  -- this both highlights the fenced code and warms the parse otter will read.
  pcall(vim.treesitter.start, buf)
  return true
end

-- Has otter actually wired this buffer up? `otter.activate` is a one-shot: if the
-- buffer holds NO chunk in an activated language at call time, it no-ops and never
-- retries on its own (so opening a doc that has no ```python block yet leaves otter
-- dormant). We detect a real activation by its raft carrying >=1 language.
local function otter_active(buf)
  local ok, keeper = pcall(require, "otter.keeper")
  local raft = ok and keeper.rafts[buf]
  return raft ~= nil and #(raft.languages or {}) > 0
end

-- Cheap pre-check: does the buffer contain a fence in one of `langs`? A plain line
-- scan (no treesitter parse), so the retry below can skip otter's full parse until
-- a relevant fence actually exists. Matches the fence's first word, so `python` and
-- `python %%` both count.
local function has_fence(buf, langs)
  local set = {}
  for _, l in ipairs(langs) do set[l] = true end
  for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    local w = line:match("^%s*```(%a[%w_]*)")
    if w and set[w] then return true end
  end
  return false
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

  local ok, otter = pcall(require, "otter")
  if not ok then
    if loud and not warned then
      warned = true
      vim.notify("bsh: config.otter is enabled but otter.nvim is not installed",
        vim.log.levels.WARN)
    end
    return
  end

  -- `.bsh.typ` (typst) is skipped: typst has no ```lang fences for otter to find.
  local ft = vim.bo[buf].filetype
  if vim.b[buf].bsh_typst then return end
  -- An empty-filetype buffer (a bare `:Bsh!` scratch) has no host highlighting to
  -- preserve, so adopt `bsh` outright; everything else keeps its filetype and is
  -- mapped onto the markdown parser in place (a no-op when it already is markdown).
  if ft == "" then
    vim.bo[buf].filetype = "bsh"; ft = "bsh"
  end
  if not map_to_markdown(buf, ft) then return end

  -- activate(languages, completion, diagnostics, tsquery). A nil tsquery makes
  -- otter use the host filetype's injections query (markdown), which captures
  -- the ```python fences. Completion flows through your existing cmp `nvim_lsp`
  -- source -- otter registers as a language server client on the buffer.
  local function go()
    pcall(vim.api.nvim_buf_call, buf, function()
      otter.activate(config.otter_languages, true, true, nil)
    end)
  end
  if has_fence(buf, config.otter_languages) then go() end

  -- otter.activate is one-shot, so a doc opened with no ```python block yet stays
  -- dormant. Retry on edits until it sticks -- so adding the FIRST fence later still
  -- wires up LSP -- then tear the watcher down. The has_fence pre-check keeps this
  -- to a line scan (no otter parse) until a relevant fence appears.
  if not otter_active(buf) then
    local group = vim.api.nvim_create_augroup("bsh_otter_retry_" .. buf, { clear = true })
    vim.api.nvim_create_autocmd({ "InsertLeave", "TextChanged" }, {
      group = group,
      buffer = buf,
      callback = function()
        if otter_active(buf) then
          pcall(vim.api.nvim_del_augroup_by_id, group)
          return
        end
        if has_fence(buf, config.otter_languages) then go() end
      end,
    })
  end
end

return M
