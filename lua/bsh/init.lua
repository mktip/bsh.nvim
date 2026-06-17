-- bsh: a "live document" buffer in the spirit of xiki/notebooks.
--
-- A *cell* is a trigger line followed by a result fence that THIS MODULE owns
-- and rewrites. Pressing <CR> on the trigger runs it and replaces the fence's
-- body in place -- so re-running is idempotent (edit the line, <CR> again, the
-- old output is replaced, never duplicated). The fence delimiters are the
-- result's start/end markers, so there is no separate END syntax to invent, and
-- the whole thing survives :w / reload and folds like normal markdown.
--
-- Step 1 implements only the `$` shell cell:
--
--     $ ls -la
--     ```out
--     total 48
--     drwxr-xr-x  5 mktips ...
--     ```
--
-- Future cell kinds (`:` paths, `https://` summaries, `>` agentic llm) plug
-- into the same dispatcher + find-or-replace-fence machinery.

local M = {}

local util = require("bsh.util")
local join_path, parse_list_args, qpath = util.join_path, util.parse_list_args, util.qpath
local tree_entry, parse_runmarker = util.tree_entry, util.parse_runmarker

local fence = require("bsh.fence")
local ns, inflight = fence.ns, fence.inflight
local fence_range, clear_inflight = fence.fence_range, fence.clear_inflight
local stage_block, stage_fence, fill_fence = fence.stage_block, fence.stage_fence, fence.fill_fence
M.foldexpr, M.foldtext = fence.foldexpr, fence.foldtext -- re-export (attach() uses require'bsh'.foldexpr)

-- User options live in bsh.config; the engine reads `config.*`, and the public
-- `require('bsh').<opt>` surface proxies to it (metatable at the bottom).
local config = require("bsh.config")

local job = require("bsh.job")
local build_argv, run_job, shell_transform, doc_cwd = job.build_argv, job.run_job, job.shell_transform, job.doc_cwd
local existing_log_link, begin_buffer_run, open_out_buffer = job.existing_log_link, job.begin_buffer_run, job.open_out_buffer
local run_shell, run_oneshot = job.run_shell, job.run_oneshot

local session = require("bsh.session")
local run_session = session.run_session
M.stop_session = session.stop_session -- re-export (BufWipeout autocmd uses require'bsh'.stop_session)

local run_agent = require("bsh.agent").run_agent

local listing = require("bsh.listing")
local run_list, open_entry, fence_open, tree_path, open_url =
  listing.run_list, listing.open_entry, listing.fence_open, listing.tree_path, listing.open_url

local namespace = require("bsh.namespace")
local ns_home, run_namespace, edit_namespace =
  namespace.ns_home, namespace.run_namespace, namespace.edit_namespace

-- Parse a fence info-string into (lang, target, session) or nil if it's not a
-- runnable cell. The run marker is a SUFFIX (`$` once / `$$` session) so the
-- language word stays first and the block still syntax-highlights:
--   $  $$  user@host$            -> bash (lang "sh"), no language word
--   python $   py $$   ruby $$   -> a language word, then optional target + marker
-- No trailing marker (a plain ```python doc block, or ```out) -> nil (inert).
-- (parse_runmarker lives in bsh.util.)

-- A MULTILINE input cell is a fenced code block whose info-string parses as a run
-- marker (see parse_runmarker). If the cursor sits anywhere inside such a block,
-- return its open/close rows, indent, language, remote target, session flag, and
-- the joined body; else nil.
local function input_fence_at(buf, row)
  local total = vim.api.nvim_buf_line_count(buf)
  local function gl(r) return vim.api.nvim_buf_get_lines(buf, r, r + 1, false)[1] or "" end
  -- find the opening fence at/above the cursor; bail if we hit a bare ``` first
  -- (that means we're below a closed block, not inside an open one)
  local openr
  for r = row, 0, -1 do
    local l = gl(r)
    if l:match("^%s*```%s*$") then return nil end
    if l:match("^%s*```%S") then openr = r; break end
  end
  if not openr then return nil end
  local lang, target, session = parse_runmarker(vim.trim(gl(openr):match("^%s*```(.*)$") or ""))
  if not lang then return nil end -- e.g. ```out / ```python (no marker) -> inert
  local closer
  for r = openr + 1, total - 1 do
    if gl(r):match("^%s*```%s*$") then closer = r; break end
  end
  if not closer or row > closer then return nil end
  return {
    open = openr, close = closer, indent = gl(openr):match("^(%s*)"),
    lang = lang, target = target, session = session,
    body = table.concat(vim.api.nvim_buf_get_lines(buf, openr + 1, closer, false), "\n"),
  }
end

-- If `row` sits inside an `out` fence's body, return its opening fence row
-- (0-indexed); else nil. Used to recognise a click on a line of a command's
-- output (for namespace menu-drilling). Bails on any other fence kind.
local function out_fence_at(buf, row)
  local function gl(r) return vim.api.nvim_buf_get_lines(buf, r, r + 1, false)[1] or "" end
  if gl(row):match("^%s*```") then return nil end -- on a fence delimiter, not a body line
  for r = row - 1, 0, -1 do
    local s = gl(r)
    if s:match("^%s*```out%s*$") then return r end
    if s:match("^%s*```%S") then return nil end  -- some other opening fence
    if s:match("^%s*```%s*$") then return nil end -- a closer above -> outside any fence
  end
  return nil
end

-- Dispatch on the current line. Returns true if something was handled, false to
-- let <CR> fall through to its default.
local function execute_cell(to_buf)
  local buf = vim.api.nvim_get_current_buf()
  local trow = vim.api.nvim_win_get_cursor(0)[1] - 1
  local line = vim.api.nvim_buf_get_lines(buf, trow, trow + 1, false)[1] or ""
  local indent = line:match("^(%s*)")

  -- <CR> on a `log` reference line opens that cell's output buffer in a split.
  local outlink = line:match("(bsh://out/%S+)")
  if outlink then open_out_buffer(outlink); return true end

  -- Cursor inside a `$`/`$$` (or `python $`/`$$`) input fence: run the WHOLE
  -- block (multiline). The owned `out` fence is staged just after the block's
  -- closing ``` (pass that row as the trigger). Checked first so a body line
  -- that happens to look like a `$ ...` trigger doesn't run on its own.
  local fc = input_fence_at(buf, trow)
  if fc then
    if fc.lang == "sh" then
      if fc.session then -- local or remote (`user@host$$`) persistent shell
        run_session(buf, "sh", fc.target, fc.close, fc.indent, fc.body, to_buf)
      else
        run_shell(buf, fc.close, fc.indent, fc.target, fc.body, to_buf)
      end
    elseif fc.target ~= "" then
      vim.notify("bsh: remote " .. fc.lang .. " cells aren't supported yet",
        vim.log.levels.WARN)
    elseif fc.session then
      run_session(buf, fc.lang, "", fc.close, fc.indent, fc.body, to_buf)
    else -- one-shot interpreter run
      run_oneshot(buf, fc.close, fc.indent, { config.python, "-c", fc.body }, to_buf)
    end
    return true
  end

  -- <C-CR> inside a namespace command's `out` fence: DRILL. Append the clicked
  -- line as one quoted arg to the (dotted) trigger and re-run IN PLACE, so the
  -- command can reinterpret it (list -> drill into one). The trigger accumulates
  -- a breadcrumb (`docker.list` -> `docker.list <id>` -> `… start`) you can edit
  -- or backspace to walk back up. On <C-CR>/g<CR> only -- never plain <CR> --
  -- because output lines are noisy and a stray <CR> shouldn't re-fire the command
  -- (`dir`/`tree` fences keep plain-<CR> nav; they're clean entry-per-line). The
  -- re-run is inline regardless of the gesture, since drilling rewrites in place.
  if to_buf then
    local mopen = out_fence_at(buf, trow)
    if mopen then
      local trig = vim.api.nvim_buf_get_lines(buf, mopen - 1, mopen, false)[1] or ""
      local tindent = trig:match("^(%s*)")
      local nsname = vim.trim(trig):match("^([%w_][%w_%.%-]*)")
      local clicked = vim.trim(line)
      if nsname and clicked ~= "" and namespace.resolves(nsname) then
        local newtrig = vim.trim(trig) .. " " .. vim.fn.shellescape(clicked)
        vim.api.nvim_buf_set_lines(buf, mopen - 1, mopen, false, { tindent .. newtrig })
        local nm, ar = newtrig:match("^([%w_][%w_%.%-]*)%s+(.+)$")
        run_namespace(buf, mopen - 1, tindent, nm, ar, false) -- inline, in place
        return true
      end
    end
  end

  -- inline shell: `[user@host]$ cmd` (one-shot) or `[user@host]$$ cmd` (shared
  -- session, local or remote). One unified match: the marker is `$`/`$$` and the
  -- greedy `%$?` captures the doubled form, so `user@host$$ cmd` parses
  -- target=`user@host` (NOT `user@host$`, which would corrupt the ssh host).
  local stgt, sdbl, scmd = line:match("^%s*(%S-)(%$%$?)%s+(.+)$")
  if scmd then
    if sdbl == "$$" then
      run_session(buf, "sh", stgt, trow, indent, scmd, to_buf)
    else
      run_shell(buf, trow, indent, stgt, scmd, to_buf)
    end
    return true
  end

  -- `https://…` on its own line : open it in the browser.
  local url = line:match("^%s*(https?://%S+)%s*$")
  if url then
    open_url(url)
    return true
  end

  -- `> instruction` : agentic llm call. The count of leading `>` beyond the
  -- first = how many preceding cells to fold in as context (`>` none, `>>` one,
  -- `>>>` two, …). Output goes in a comment-delimited region below.
  local gts, instruction = line:match("^%s*(>+)%s+(.+)$")
  if instruction then
    run_agent(buf, trow, indent, instruction, #gts - 1)
    return true
  end

  -- `[user@host]: path` listing. To avoid firing on prose like "TODO: fix", the
  -- colon must be the first non-blank char (local) or the target must name a
  -- host (`user@host`). Remote listings therefore use the user@host form.
  local ltarget, lrest = line:match("^%s*(%S-):%s+(.+)$")
  if lrest and (ltarget == "" or ltarget:find("@")) then
    run_list(buf, trow, indent, ltarget, lrest)
    return true
  end

  -- <CR> on an entry inside a `dir`/`tree` fence: open the file / drill into it.
  local open, tag = fence_open(buf, trow)
  if open then
    local trig = vim.api.nvim_buf_get_lines(buf, open - 1, open, false)[1] or ""
    local ttarget, trest = trig:match("^%s*(%S-):%s+(.+)$")
    if not trest then
      -- Not a `:` directive -- maybe a namespace listing (dotted trigger, e.g.
      -- `llm.tools`). Reconstruct its dir under $BSH_HOME and navigate the
      -- entries the same way `:` does, but staying DOTTED: drilling into a subdir
      -- rewrites the trigger to the deeper namespace, files open for editing.
      local nsdot = trig:match("^%s*([%w_][%w_%.%-]*)%s*$")
      -- a namespace listing's trigger carries a trailing dot (`demo.`); strip it
      -- so we never build `demo..child`
      local clean = nsdot and (nsdot:gsub("%.+$", "")) or nil
      local home = clean and ns_home() or ""
      local base = home ~= "" and (home .. "/" .. (clean:gsub("%.", "/"))) or ""
      if base == "" or vim.fn.isdirectory(base) ~= 1 or tag ~= "dir" then return false end
      local entry = (line:gsub("^%s+", "")):gsub("%s+$", "")
      if entry == "" then return false end
      local tindent = trig:match("^(%s*)")
      if entry == "../" then -- walk up one namespace segment (drop to `:` at root)
        local parent = clean:match("^(.+)%.[^.]+$")
        if parent then
          run_namespace(buf, open - 1, tindent, parent .. ".") -- list the parent
        else
          local up = vim.fn.fnamemodify(base, ":h")
          vim.api.nvim_buf_set_lines(buf, open - 1, open, false, { tindent .. ": " .. up })
          run_list(buf, open - 1, tindent, "", up)
        end
      elseif entry:sub(-1) == "/" then -- drill deeper: descend + list (append `.`)
        run_namespace(buf, open - 1, tindent, clean .. "." .. entry:sub(1, -2) .. ".")
      else
        open_entry("", base .. "/" .. entry)
      end
      return true
    end
    local base, flags = parse_list_args(trest)

    local full, isdir
    if tag == "tree" then
      full, isdir = tree_path(buf, open + 1, trow, base)
      if not full then return false end -- root/summary/blank line
    else
      local entry = (line:gsub("^%s+", "")):gsub("%s+$", "")
      if entry == "" then return false end
      isdir = entry:sub(-1) == "/"
      full = join_path(base, isdir and entry:sub(1, -2) or entry)
    end

    if isdir then
      -- rewrite the trigger's path and re-list in place (oil-style navigation),
      -- preserving the cell's mode (tree stays tree) and -H flag
      local tindent = trig:match("^(%s*)")
      local suffix = (flags.tree and " -T" or "") .. (flags.hidden and " -H" or "")
      local newtrig = tindent .. (ttarget ~= "" and (ttarget .. ": ") or ": ") .. full .. suffix
      vim.api.nvim_buf_set_lines(buf, open - 1, open, false, { newtrig })
      run_list(buf, open - 1, tindent, ttarget, full .. suffix)
    else
      open_entry(ttarget, full)
    end
    return true
  end

  -- `foo.bar!` : edit/define a command's source (authoring). Checked before the
  -- run branches; `!` never appears in the run/args forms, and a prose `word!`
  -- is guarded by a confirm before anything is created.
  local nsbang = line:match("^%s*([%w_][%w_%.%-]*)!%s*$")
  if nsbang and edit_namespace(nsbang) then
    return true
  end

  -- `namespace` cell: a dotted identifier resolving under $BSH_HOME, optionally
  -- followed by args (`llm.tools.weather Ankara`, `... > out.txt`, `... | grep C`).
  -- The args go through the shell (see run_ns_exec), so the cell is a true shell
  -- continuation. Checked last and gated on the FIRST token resolving, so prose
  -- (which won't resolve) falls through untouched -- args form tried first.
  local nsname, nsargs = line:match("^%s*([%w_][%w_%.%-]*)%s+(.+)$")
  if nsname and run_namespace(buf, trow, indent, nsname, nsargs, to_buf) then
    return true
  end
  local dotted = line:match("^%s*([%w_][%w_%.%-]*)%s*$")
  if dotted and run_namespace(buf, trow, indent, dotted, nil, to_buf) then
    return true
  end

  return false
end

-- Turn ANY buffer into a lab: the cell-running <CR>, comment style and folding,
-- WITHOUT changing its filetype (so an existing markdown file keeps its markdown
-- syntax highlighting). Idempotent -- safe to call more than once on a buffer.
function M.attach(buf)
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
  if vim.b[buf].bsh_attached then return end
  vim.b[buf].bsh_attached = true

  vim.bo[buf].commentstring = "<!-- %s -->"
  -- fold each result fence; start fully open (za on the trigger toggles one)
  vim.api.nvim_buf_call(buf, function()
    vim.opt_local.foldmethod = "expr"
    vim.opt_local.foldexpr = "v:lua.require'bsh'.foldexpr(v:lnum)"
    vim.opt_local.foldtext = "v:lua.require'bsh'.foldtext()"
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
end

M.config = function()
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

  -- attach on the dedicated filetype...
  vim.api.nvim_create_autocmd("FileType", {
    pattern = "bsh",
    callback = function(args) M.attach(args.buf) end,
  })
  -- ...and on the `*.bsh.md` markdown convention (filename, not filetype, since
  -- the compound-filetype FileType event we can't rely on never enters into it).
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
    pattern = { "*.bsh.md", "*.bsh.markdown" },
    callback = function(args) M.attach(args.buf) end,
  })

  -- tear a buffer's persistent `$$` shell down when the buffer is wiped.
  vim.api.nvim_create_autocmd("BufWipeout", {
    callback = function(args) M.stop_session(args.buf) end,
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

-- Public option surface: `require('bsh').python`, `…remote_login`, etc. proxy to
-- bsh.config so reads and writes hit the single source of truth the engine reads.
-- Set last, after all M.<fn> fields exist, so it only governs the option keys.
setmetatable(M, {
  __index = function(_, k)
    if config[k] ~= nil then return config[k] end
  end,
  __newindex = function(t, k, v)
    if config[k] ~= nil then config[k] = v else rawset(t, k, v) end
  end,
})

return M
