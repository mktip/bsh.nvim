-- bsh's engine (loaded on the first bsh buffer; init.lua is the light front door).
--
-- bsh: a shell in a buffer, in the spirit of xiki and notebooks.
--
-- A *cell* is a trigger line followed by a result fence that bsh owns and
-- rewrites. <CR> on the trigger runs it and replaces the fence's body in place,
-- so re-running is idempotent: edit the line, <CR> again, the old output is
-- replaced, never duplicated. The fence delimiters mark the result, so there is
-- no END syntax, and the file survives :w / reload and folds like markdown:
--
--     % ls -la
--     ```out
--     total 48
--     ```
--
-- What a line is comes from bsh.cell (the grammar); this module dispatches on it
-- (execute_cell), adds the keymaps, and wires up the buffer (attach).

local M = {}

-- User options live in bsh.config; the engine reads `config.*` (init.lua proxies
-- the public `require('bsh').<opt>` surface to it).
local config = require("bsh.config")
local util = require("bsh.util")
local fence = require("bsh.fence")
local job = require("bsh.job")
local session = require("bsh.session")
local listing = require("bsh.listing")
local namespace = require("bsh.namespace")
local cell = require("bsh.cell")
local edit = require("bsh.edit")

-- bundled cell kinds, written as rules (yours in config.rules come first)
cell.register(require("bsh.contrib.agent").rule)

M.stop_session = session.stop_session

-- If `row` sits inside a `menu` fence's body, return its opening fence row
-- (0-indexed); else nil. A `menu` fence is produced when a namespace command
-- exits config.menu_exit to DECLARE its output drillable (each line a next arg),
-- so a plain <CR> on one of its lines is a safe drill. Bails on any other fence.
local function menu_fence_at(buf, row)
  local function gl(r) return vim.api.nvim_buf_get_lines(buf, r, r + 1, false)[1] or "" end
  if gl(row):match("^%s*```") then return nil end -- on a fence delimiter, not a body line
  for r = row - 1, 0, -1 do
    local s = gl(r)
    if s:match("^%s*```menu%s*$") then return r end
    if s:match("^%s*```%S") then return nil end   -- some other opening fence
    if s:match("^%s*```%s*$") then return nil end -- a closer above -> outside any fence
  end
  return nil
end

-- Lines a visual-mode <CR> selected above a rule's cell, handed to that rule as
-- ctx.selection by execute_cell (which clears it).
local selection_lines

-- <CR> on an entry line inside a `dir`/`tree` fence. Returns true/false when the
-- cursor is in such a fence (handled or not), nil when it isn't.
local function open_listing_entry(buf, trow, line)
  local open, tag = listing.fence_open(buf, trow)
  if open then
    local trig = vim.api.nvim_buf_get_lines(buf, open - 1, open, false)[1] or ""
    local ttarget, trest = trig:match("^%s*(%S-):%s+(.+)$")
    if not trest then
      -- Not a `:` directive -- maybe a namespace listing (dotted trigger, e.g.
      -- `demo`). Reconstruct its dir under $BSH_HOME and navigate the
      -- entries the same way `:` does, but staying DOTTED: drilling into a subdir
      -- rewrites the trigger to the deeper namespace, files open for editing.
      local nsdot = trig:match("^%s*([%w_][%w_%.%-]*)%s*$")
      -- a namespace listing's trigger carries a trailing dot (`demo.`); strip it
      -- so we never build `demo..child`
      local clean = nsdot and (nsdot:gsub("%.+$", "")) or nil
      if not clean or tag ~= "dir" then return false end
      local home = namespace.ns_home()
      local base = home ~= "" and (home .. "/" .. (clean:gsub("%.", "/"))) or ""
      if base == "" or vim.fn.isdirectory(base) ~= 1 then return false end
      local entry = (line:gsub("^%s+", "")):gsub("%s+$", "")
      if entry == "" then return false end
      local tindent = trig:match("^(%s*)")
      if entry == "../" then -- walk up one namespace segment (drop to `:` at root)
        local parent = clean:match("^(.+)%.[^.]+$")
        if parent then
          namespace.run_namespace(buf, open - 1, tindent, parent .. ".") -- list the parent
        else
          local up = vim.fn.fnamemodify(base, ":h")
          vim.api.nvim_buf_set_lines(buf, open - 1, open, false, { tindent .. ": " .. up })
          listing.run_list(buf, open - 1, tindent, "", up)
        end
      elseif entry:sub(-1) == "/" then -- drill deeper: descend + list (append `.`)
        namespace.run_namespace(buf, open - 1, tindent, clean .. "." .. entry:sub(1, -2) .. ".")
      else
        listing.open_entry("", base .. "/" .. entry)
      end
      return true
    end
    local base, flags = util.parse_list_args(trest)

    -- `tree` fences fold in place: a directory node toggles (expand splices
    -- its children below it at one deeper indent; collapse removes them),
    -- siblings untouched -- only `../` (always depth 0) still rewrites the
    -- trigger and re-lists, same as `dir` mode's walk-up.
    if tag == "tree" then
      if vim.trim(line) == "../" then
        local tindent = trig:match("^(%s*)")
        local suffix = (flags.tree and " -T" or "") .. (flags.hidden and " -H" or "")
        local full = util.join_path(base, "..")
        local newtrig = tindent .. (ttarget ~= "" and (ttarget .. ": ") or ": ") .. full .. suffix
        vim.api.nvim_buf_set_lines(buf, open - 1, open, false, { newtrig })
        listing.run_list(buf, open - 1, tindent, ttarget, full .. suffix)
        return true
      end
      local depth, name, is_dir = util.fold_entry(line)
      if not depth then return false end -- blank line: not an entry
      if is_dir then
        listing.toggle_tree_node(buf, open, trow, ttarget, base, flags.hidden)
      else
        local full = listing.fold_path(buf, open + 1, trow, base)
        if full then listing.open_entry(ttarget, full) end
      end
      return true
    end

    local entry = (line:gsub("^%s+", "")):gsub("%s+$", "")
    if entry == "" then return false end
    local isdir = entry:sub(-1) == "/"
    local full = util.join_path(base, isdir and entry:sub(1, -2) or entry)

    if isdir then
      -- rewrite the trigger's path and re-list in place (oil-style navigation)
      local tindent = trig:match("^(%s*)")
      local suffix = flags.hidden and " -H" or ""
      local newtrig = tindent .. (ttarget ~= "" and (ttarget .. ": ") or ": ") .. full .. suffix
      vim.api.nvim_buf_set_lines(buf, open - 1, open, false, { newtrig })
      listing.run_list(buf, open - 1, tindent, ttarget, full .. suffix)
    else
      listing.open_entry(ttarget, full)
    end
    return true
  end
  return nil
end

-- How each definite line-cell kind (see bsh.cell) runs. The tentative namespace
-- kinds are handled last in execute_cell.
local LINE_RUN = {
  shell = function(buf, trow, c, to_buf)
    require("bsh.history").add(c.target, c.body)
    if c.session then
      session.run_session(buf, "sh", c.target, trow, c.indent, c.body, to_buf, trow)
    else
      job.run_shell(buf, trow, c.indent, c.target, c.body, to_buf)
    end
  end,
  url = function(_, _, c) listing.open_url(c.url) end,
  list = function(buf, trow, c) listing.run_list(buf, trow, c.indent, c.target, c.body) end,
}

-- Dispatch on the current line. Returns true if something was handled, false to
-- let <CR> fall through to its default.
local function execute_cell(to_buf)
  local buf = vim.api.nvim_get_current_buf()
  local trow = vim.api.nvim_win_get_cursor(0)[1] - 1
  local line = vim.api.nvim_buf_get_lines(buf, trow, trow + 1, false)[1] or ""
  local indent = line:match("^(%s*)")

  -- <CR> on a `log` reference line opens that cell's output buffer in a split.
  local outlink = line:match("(bsh://out/%S+)")
  if outlink then
    job.open_out_buffer(outlink); return true
  end

  -- Cursor inside a `%`/`%%` (or `python %`/`%%`) input fence: run the WHOLE
  -- block (multiline). The owned `out` fence is staged just after the block's
  -- closing ``` (pass that row as the trigger). Checked first so a body line
  -- that happens to look like a `% ...` trigger doesn't run on its own.
  local fc = cell.input_fence_at(buf, trow)
  if fc then
    if fc.lang == "sh" then
      if fc.session then -- local or remote (`user@host%%`) persistent shell
        session.run_session(buf, "sh", fc.target, fc.close, fc.indent, fc.body, to_buf, fc.open)
      else
        job.run_shell(buf, fc.close, fc.indent, fc.target, fc.body, to_buf)
      end
    elseif fc.session then -- persistent interpreter, local or remote (`python user@host%%`)
      session.run_session(buf, fc.lang, fc.target, fc.close, fc.indent, fc.body, to_buf, fc.open)
    elseif (config.languages or {})[fc.lang] then -- a language of yours, once: the block on its stdin
      local eof = "__BSH_EOF_" .. vim.uv.hrtime() .. "__"
      local cmd = config.languages[fc.lang].cmd .. " <<'" .. eof .. "'\n" .. fc.body .. "\n" .. eof
      job.run_oneshot(buf, fc.close, fc.indent, job.build_argv(fc.target, cmd), to_buf)
    elseif fc.target ~= "" then -- one-shot along a route: the interpreter runs at the far end
      job.run_oneshot(buf, fc.close, fc.indent,
        job.build_argv(fc.target, config.python .. " -c " .. vim.fn.shellescape(fc.body)), to_buf)
    else -- one-shot local interpreter
      job.run_oneshot(buf, fc.close, fc.indent, { config.python, "-c", fc.body }, to_buf)
    end
    return true
  end

  -- Plain <CR> inside a `menu` fence: DRILL. The command DECLARED its output a
  -- menu (by exiting config.menu_exit -> rendered as ```menu), so every line is a
  -- valid next arg: append the clicked line (one quoted arg) to the dotted
  -- trigger and re-run IN PLACE, so the command reinterprets it (list -> drill
  -- into one). The trigger accumulates a breadcrumb (`docker.list` ->
  -- `docker.list <id>` -> `… start`) you can edit or backspace to walk back up.
  -- Plain <CR> is safe here precisely because the command opted in; <C-CR> stays
  -- "open in a side buffer", so we only drill on a plain <CR> (not to_buf).
  if not to_buf then
    local mopen = menu_fence_at(buf, trow)
    if mopen then
      local trig = vim.api.nvim_buf_get_lines(buf, mopen - 1, mopen, false)[1] or ""
      local tindent = trig:match("^(%s*)")
      local nsname = vim.trim(trig):match("^([%w_][%w_%.%-]*)")
      local clicked = vim.trim(line)
      if nsname and clicked ~= "" then
        local newtrig = vim.trim(trig) .. " " .. vim.fn.shellescape(clicked)
        vim.api.nvim_buf_set_lines(buf, mopen - 1, mopen, false, { tindent .. newtrig })
        local nm, ar = newtrig:match("^([%w_][%w_%.%-]*)%s+(.+)$")
        namespace.run_namespace(buf, mopen - 1, tindent, nm, ar, false) -- inline, in place
        return true
      end
    end
  end

  -- a rule: your config.rules, then bundled kinds like the `>` agent (plumber
  -- style). Its `run` returns a shell command to run as a `%` cell, false to
  -- pass, else it handled the line (often through ctx.run).
  local rule, caps = cell.rule_for(line)
  local selection = selection_lines
  selection_lines = nil
  if rule then
    local res = rule.run(M._rule_ctx(buf, trow, line, indent, to_buf, rule, selection), unpack(caps))
    if type(res) == "string" then
      job.run_shell(buf, trow, indent, "", res, to_buf)
      return true
    end
    if res ~= false then return true end
  end

  local c = cell.parse(line)
  if c and LINE_RUN[c.kind] then
    LINE_RUN[c.kind](buf, trow, c, to_buf)
    return true
  end

  -- <CR> on an entry inside a `dir`/`tree` fence: open the file / drill into it.
  -- (Before the namespace kinds: an entry like `notes.txt` would parse as one.)
  local handled = open_listing_entry(buf, trow, line)
  if handled ~= nil then return handled end

  -- `foo.bar!` edits/defines a command's source; `foo.bar [args]` runs one. Both
  -- are tentative: they only fire if the name resolves (or, for `!`, after a
  -- confirm), so prose falls through untouched.
  if c and c.kind == "nsedit" then return namespace.edit_namespace(c.name) and true or false end
  if c and c.kind == "ns" then
    return namespace.run_namespace(buf, trow, c.indent, c.name, c.args, to_buf) and true or false
  end
  return false
end

-- <M-CR>, REPL style. Insert mode, on a one-line cell: run it, then open a fresh
-- prompt with the same prefix below its output (anywhere else: a plain newline).
-- Normal mode never runs anything: on a cell's trigger or inside its output it
-- opens a new prompt with that cell's prefix below the output; elsewhere a bare
-- `<marker> ` prompt below the cursor line.
local function run_and_continue(insert)
  local buf = vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  if insert then
    local prefix = edit.prompt_prefix(buf, row)
    if not prefix then
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "ni", false)
      return
    end
    if execute_cell(false) then edit.open_prompt_below(buf, row, prefix) end
    return
  end
  local trow = row
  local prefix = edit.prompt_prefix(buf, row)
  local fc = cell.input_fence_at(buf, row - 1)
  if fc then -- in a multiline ```% block: a one-line prompt on the same route, below its output
    trow = fc.close + 1
    prefix = fc.indent .. fc.target .. config.marker .. (fc.session and config.marker or "") .. " "
  elseif not prefix then -- inside a cell's output? use the cell that owns it
    local open = fence.output_at(buf, row)
    if open and open > 1 then
      trow = open - 1
      prefix = edit.prompt_prefix(buf, trow)
    end
  end
  if prefix then return edit.open_prompt_below(buf, trow, prefix) end
  local p = (vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""):match("^(%s*)") .. config.marker .. " "
  vim.api.nvim_buf_set_lines(buf, row, row, false, { p })
  vim.api.nvim_win_set_cursor(0, { row + 1, #p })
  vim.cmd("startinsert!")
end

-- Turn ANY buffer into a lab: the cell-running <CR>, comment style and folding,
-- WITHOUT changing its filetype (so an existing markdown file keeps its markdown
-- syntax highlighting). Idempotent -- safe to call more than once on a buffer.
function M.attach(buf)
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
  if vim.b[buf].bsh_attached then return end
  vim.b[buf].bsh_attached = true

  vim.bo[buf].commentstring = "<!-- %s -->"

  -- A `bsh` buffer is a markdown-fenced doc: point treesitter at the markdown parser
  -- so the fenced code is highlighted AND exposed as a treesitter *injection* -- what
  -- otter (LSP) and conform.nvim's `injected` formatter both read. Only the dedicated
  -- `bsh` filetype needs this (`.bsh.md` is already markdown);
  -- foreign `:Bsh!` filetypes are mapped, guarded, in bsh.otter. Unconditional (not
  -- otter-gated) so highlighting/formatting work even with config.otter off.
  if vim.bo[buf].filetype == "bsh" then
    pcall(vim.treesitter.language.register, "markdown", "bsh")
    pcall(vim.treesitter.start, buf)
  end
  -- fold each result fence; start fully open (za on the trigger toggles one)
  vim.api.nvim_buf_call(buf, function()
    vim.opt_local.foldmethod = "expr"
    vim.opt_local.foldexpr = "v:lua.require'bsh.fence'.foldexpr(v:lnum)"
    vim.opt_local.foldtext = "v:lua.require'bsh.fence'.foldtext()"
    vim.opt_local.foldlevel = 99
    vim.opt_local.fillchars:append("fold: ")
  end)

  local function run_here(to_buf)
    if not execute_cell(to_buf) then
      -- not a cell: preserve the default <CR> (down to first non-blank)
      vim.cmd("normal! +")
    end
  end
  vim.keymap.set("n", "<CR>", function() run_here(false) end,
    { buffer = buf, desc = "bsh: run cell (output inline)" })
  -- <C-CR> (and the always-works fallback g<CR>): run with output in a side buffer.
  -- NOTE: many terminals don't pass <C-CR> distinctly from <CR> unless they speak
  -- the kitty keyboard protocol -- hence the g<CR> fallback (see README).
  vim.keymap.set("n", "<C-CR>", function() run_here(true) end,
    { buffer = buf, desc = "bsh: run cell (output to side buffer)" })
  vim.keymap.set("n", "g<CR>", function() run_here(true) end,
    { buffer = buf, desc = "bsh: run cell (output to side buffer)" })

  -- Visual <CR>: when the selection ENDS on a rule's cell (a `>` agent cell, or
  -- a kind of your own), run it with the lines above it in the selection handed
  -- over as ctx.selection. Any other selection keeps the default <CR> motion.
  vim.keymap.set("x", "<CR>", function()
    local a, b = vim.fn.line("v"), vim.fn.line(".")
    local first, last = math.min(a, b), math.max(a, b)
    local trig = vim.api.nvim_buf_get_lines(buf, last - 1, last, false)[1] or ""
    if first < last and cell.rule_for(trig) then
      selection_lines = vim.api.nvim_buf_get_lines(buf, first - 1, last - 1, false)
      vim.cmd("normal! \27")
      vim.api.nvim_win_set_cursor(0, { last, 0 })
      if not execute_cell(false) then selection_lines = nil end
    else
      vim.cmd("normal! +")
    end
  end, { buffer = buf, desc = "bsh: run the cell ending the selection, selection attached" })

  -- ]c / [c jump between cells; io / ao select a cell's output (yio, dao, vio).
  vim.keymap.set({ "n", "x", "o" }, "]c", function() edit.jump_cell(1) end,
    { buffer = buf, desc = "bsh: next cell" })
  vim.keymap.set({ "n", "x", "o" }, "[c", function() edit.jump_cell(-1) end,
    { buffer = buf, desc = "bsh: previous cell" })
  vim.keymap.set({ "x", "o" }, "io", edit.output_object(false),
    { buffer = buf, expr = true, desc = "bsh: inner output (a result fence's body)" })
  vim.keymap.set({ "x", "o" }, "ao", edit.output_object(true),
    { buffer = buf, expr = true, desc = "bsh: around output (the whole result fence)" })
  vim.keymap.set("i", "<M-CR>", function() run_and_continue(true) end,
    { buffer = buf, desc = "bsh: run this cell, then start the next one below it" })
  vim.keymap.set("n", "<M-CR>", function() run_and_continue(false) end,
    { buffer = buf, desc = "bsh: run this cell, then start the next one below it" })

  -- <C-c> cancels the running cell under the cursor (one-shot: stop; session:
  -- SIGINT the running command, keep the session). <C-k> ("kill") resets the
  -- session for the cell under the cursor (<C-k> has no default normal-mode
  -- meaning, unlike most ctrl keys). Both are also :BshCancel / :BshReset.
  vim.keymap.set("n", "<C-c>", session.cancel_here,
    { buffer = buf, desc = "bsh: cancel the running cell under the cursor" })
  vim.keymap.set("n", "<C-k>", function() session.reset_here(false) end,
    { buffer = buf, desc = "bsh: reset the session for the cell under the cursor" })
  vim.api.nvim_buf_create_user_command(buf, "BshCancel", function() session.cancel_here() end,
    { desc = "cancel the running cell under the cursor" })
  vim.api.nvim_buf_create_user_command(buf, "BshReset", function(o) session.reset_here(o.bang) end,
    { bang = true, desc = "reset the session for the cell under the cursor (! = all in buffer)" })

  -- each rule's own keys/commands (the agent's :BshThinking, :BshForget...)
  for _, r in ipairs(cell.rules_list()) do
    if r.attach then r.attach(buf) end
  end

  -- <localleader>r / :BshReplay — replay this session from the top through the
  -- cell under the cursor, into a fresh interpreter (resets first, then re-runs
  -- every matching session cell in document order).
  vim.keymap.set("n", "<localleader>r", session.replay_here,
    { buffer = buf, desc = "bsh: replay the session up to (and incl.) the cell under the cursor" })
  vim.api.nvim_buf_create_user_command(buf, "BshReplay", function() session.replay_here() end,
    { desc = "replay this session from the top through the cell under the cursor (fresh interpreter)" })

  -- optional: real LSP inside ```python fences via otter.nvim. No-op when otter
  -- isn't installed or config.otter is off (see lua/bsh/otter.lua).
  require("bsh.otter").activate(buf)
  -- completion from wherever the cell runs (see lua/bsh/complete.lua)
  require("bsh.complete").attach(buf)
  -- per-route command history: <C-p>/<C-n> on a prompt, :BshHistory
  require("bsh.history").attach(buf)
end

-- The ctx a rule's run gets: where the cell is, the visual selection (if <CR>
-- came from one), and `run` -- stream a command's output into the cell's own
-- fence. ctx.run(cmd, opts): cmd is an argv list or a shell string; opts:
--   route        run a shell string at the end of a route (`me@server`); default local
--   cwd          default: the doc's folder (local runs)
--   tag          the fence tag (default: the rule's tag, else "out")
--   placeholder  shown until output arrives (default "...running...")
--   decode       function(raw_stdout_so_far) -> text, for protocols (JSON events...)
--   on_done      function(first, last): the finished body rows (0-indexed)
-- Output is streamed live; a ``` in it is neutralised so it can't close the
-- fence; stderr and the exit code are shown only when the command fails.
function M._rule_ctx(buf, row, line, indent, to_buf, rule, selection)
  local ctx = { buf = buf, row = row, line = line, indent = indent, to_buf = to_buf,
    selection = selection, cwd = job.doc_cwd(buf) }
  function ctx.run(cmd, opts)
    opts = opts or {}
    local argv = type(cmd) == "table" and cmd or job.build_argv(opts.route or "", cmd)
    local tag = opts.tag or rule.tag or "out"
    if not fence.OWNED_TAGS[tag] then fence.own_tag(tag) end
    local function clean(l) return (l:gsub("```", "'''")) end
    local mark = fence.stage_fence(buf, row, indent, tag, opts.placeholder or "...running...")
    job.run_job(buf, indent, mark, argv, (opts.route or "") == "" and (opts.cwd or ctx.cwd) or nil,
      function(out, err, code)
        local lines = {}
        for _, l in ipairs(out) do lines[#lines + 1] = clean(l) end
        if code ~= 0 then
          local e = {}
          for _, l in ipairs(err) do if l ~= "" then e[#e + 1] = clean(l) end end
          if #e > 0 then lines[#lines + 1] = "[stderr]"; vim.list_extend(lines, e) end
          lines[#lines + 1] = "[exit " .. code .. "]"
        end
        return lines
      end, clean, nil, nil, nil, opts.decode, opts.on_done)
  end
  return ctx
end

-- a buffer's persistent sessions and fold cache go with it
vim.api.nvim_create_autocmd("BufWipeout", {
  group = vim.api.nvim_create_augroup("bsh_core", { clear = true }),
  callback = function(args)
    session.stop_session(args.buf)
    fence.forget_folds(args.buf)
  end,
})

-- the rules have declared their options by now: what's left is a typo
require("bsh.options").warn_unknown()

return M
