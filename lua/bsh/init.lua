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

local util = require("bsh.util")
local join_path, parse_list_args, qpath = util.join_path, util.parse_list_args, util.qpath
local fold_entry, parse_runmarker = util.fold_entry, util.parse_runmarker

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
local existing_log_link, begin_buffer_run, open_out_buffer = job.existing_log_link, job.begin_buffer_run,
    job.open_out_buffer
local run_shell, run_oneshot = job.run_shell, job.run_oneshot

local session = require("bsh.session")
local run_session = session.run_session
M.stop_session = session.stop_session -- re-export (BufWipeout autocmd uses require'bsh'.stop_session)

local run_agent = require("bsh.agent").run_agent

local listing = require("bsh.listing")
local run_list, open_entry, fence_open, fold_path, toggle_tree_node, open_url =
    listing.run_list, listing.open_entry, listing.fence_open, listing.fold_path, listing.toggle_tree_node,
    listing.open_url

local cell = require("bsh.cell")

local namespace = require("bsh.namespace")
local ns_home, run_namespace, edit_namespace =
    namespace.ns_home, namespace.run_namespace, namespace.edit_namespace

-- Parse a fence info-string into (lang, target, session) or nil if it's not a
-- runnable cell. The run marker is a SUFFIX (`%` once / `%%` session) so the
-- language word stays first and the block still syntax-highlights:
--   %  %%  user@host%            -> bash (lang "sh"), no language word
--   python %   py %%   ruby %%   -> a language word, then optional target + marker
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
    if l:match("^%s*```%S") then
      openr = r; break
    end
  end
  if not openr then return nil end
  local lang, target, session = parse_runmarker(vim.trim(gl(openr):match("^%s*```(.*)$") or ""), config.marker)
  if not lang then return nil end -- e.g. ```out / ```python (no marker) -> inert
  local closer
  for r = openr + 1, total - 1 do
    if gl(r):match("^%s*```%s*$") then
      closer = r; break
    end
  end
  if not closer or row > closer then return nil end
  return {
    open = openr,
    close = closer,
    indent = gl(openr):match("^(%s*)"),
    lang = lang,
    target = target,
    session = session,
    body = table.concat(vim.api.nvim_buf_get_lines(buf, openr + 1, closer, false), "\n"),
  }
end

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

-- Lines a visual-mode <CR> selected above an agent cell, consumed by that cell's
-- dispatch (see execute_cell) and cleared by it.
local attach_lines

-- <CR> on an entry line inside a `dir`/`tree` fence. Returns true/false when the
-- cursor is in such a fence (handled or not), nil when it isn't.
local function open_listing_entry(buf, trow, line)
  local open, tag = fence_open(buf, trow)
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

    -- `tree` fences fold in place: a directory node toggles (expand splices
    -- its children below it at one deeper indent; collapse removes them),
    -- siblings untouched -- only `../` (always depth 0) still rewrites the
    -- trigger and re-lists, same as `dir` mode's walk-up.
    if tag == "tree" then
      if vim.trim(line) == "../" then
        local tindent = trig:match("^(%s*)")
        local suffix = (flags.tree and " -T" or "") .. (flags.hidden and " -H" or "")
        local full = join_path(base, "..")
        local newtrig = tindent .. (ttarget ~= "" and (ttarget .. ": ") or ": ") .. full .. suffix
        vim.api.nvim_buf_set_lines(buf, open - 1, open, false, { newtrig })
        run_list(buf, open - 1, tindent, ttarget, full .. suffix)
        return true
      end
      local depth, name, is_dir = fold_entry(line)
      if not depth then return false end -- blank line: not an entry
      if is_dir then
        toggle_tree_node(buf, open, trow, ttarget, base, flags.hidden)
      else
        local full = fold_path(buf, open + 1, trow, base)
        if full then open_entry(ttarget, full) end
      end
      return true
    end

    local entry = (line:gsub("^%s+", "")):gsub("%s+$", "")
    if entry == "" then return false end
    local isdir = entry:sub(-1) == "/"
    local full = join_path(base, isdir and entry:sub(1, -2) or entry)

    if isdir then
      -- rewrite the trigger's path and re-list in place (oil-style navigation)
      local tindent = trig:match("^(%s*)")
      local suffix = flags.hidden and " -H" or ""
      local newtrig = tindent .. (ttarget ~= "" and (ttarget .. ": ") or ": ") .. full .. suffix
      vim.api.nvim_buf_set_lines(buf, open - 1, open, false, { newtrig })
      run_list(buf, open - 1, tindent, ttarget, full .. suffix)
    else
      open_entry(ttarget, full)
    end
    return true
  end
  return nil
end

-- How each definite line-cell kind (see bsh.cell) runs. The tentative namespace
-- kinds are handled last in execute_cell.
local LINE_RUN = {
  shell = function(buf, trow, c, to_buf)
    if c.session then
      run_session(buf, "sh", c.target, trow, c.indent, c.body, to_buf, trow)
    else
      run_shell(buf, trow, c.indent, c.target, c.body, to_buf)
    end
  end,
  url = function(_, _, c) open_url(c.url) end,
  agent = function(buf, trow, c)
    local attached = attach_lines
    attach_lines = nil
    run_agent(buf, trow, c.indent, c.body, c.stateful, c.template, c.bang, attached)
  end,
  list = function(buf, trow, c) run_list(buf, trow, c.indent, c.target, c.body) end,
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
    open_out_buffer(outlink); return true
  end

  -- Cursor inside a `%`/`%%` (or `python %`/`%%`) input fence: run the WHOLE
  -- block (multiline). The owned `out` fence is staged just after the block's
  -- closing ``` (pass that row as the trigger). Checked first so a body line
  -- that happens to look like a `% ...` trigger doesn't run on its own.
  local fc = input_fence_at(buf, trow)
  if fc then
    if fc.lang == "sh" then
      if fc.session then -- local or remote (`user@host%%`) persistent shell
        run_session(buf, "sh", fc.target, fc.close, fc.indent, fc.body, to_buf, fc.open)
      else
        run_shell(buf, fc.close, fc.indent, fc.target, fc.body, to_buf)
      end
    elseif fc.session then -- persistent interpreter, local or remote (`python user@host%%`)
      run_session(buf, fc.lang, fc.target, fc.close, fc.indent, fc.body, to_buf, fc.open)
    elseif fc.target ~= "" then -- one-shot along a route: the interpreter runs at the far end
      run_oneshot(buf, fc.close, fc.indent,
        build_argv(fc.target, config.python .. " -c " .. vim.fn.shellescape(fc.body)), to_buf)
    else -- one-shot local interpreter
      run_oneshot(buf, fc.close, fc.indent, { config.python, "-c", fc.body }, to_buf)
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
        run_namespace(buf, mopen - 1, tindent, nm, ar, false) -- inline, in place
        return true
      end
    end
  end

  -- a rule from config.rules (user-defined cell kinds, plumber style). Its `run`
  -- returns a shell command to run as a `%` cell, false to pass, else handled.
  local rule, caps = cell.user_rule(line)
  if rule then
    local res = rule.run({ buf = buf, row = trow, line = line, indent = indent, to_buf = to_buf },
      unpack(caps))
    if type(res) == "string" then
      run_shell(buf, trow, indent, "", res, to_buf)
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
  if c and c.kind == "nsedit" then return edit_namespace(c.name) and true or false end
  if c and c.kind == "ns" then
    return run_namespace(buf, trow, c.indent, c.name, c.args, to_buf) and true or false
  end
  return false
end

-- Is `line` (outside any fence) a cell trigger? `nxt` is the line below it: any
-- line that already owns a result fence counts, which covers `name.space` cells.
local function is_trigger(line, nxt)
  local tag = (nxt or ""):match("^%s*```(%S+)%s*$")
  if tag and fence.OWNED_TAGS[tag] then return true end
  local c = cell.parse(line)
  if c and c.kind ~= "ns" and c.kind ~= "nsedit" then return true end -- ns: only with a fence
  local info = line:match("^%s*```(.+)$")
  return info ~= nil and parse_runmarker(vim.trim(info), config.marker) ~= nil
end

-- 1-indexed rows of every cell trigger in `buf`, top to bottom (lines inside a
-- fence are skipped, except a runnable input fence's opener).
local function cell_rows(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local rows, infence = {}, false
  for i, l in ipairs(lines) do
    if infence then
      if l:match("^%s*```%s*$") then infence = false end
    else
      if is_trigger(l, lines[i + 1]) then rows[#rows + 1] = i end
      if l:match("^%s*```") then infence = true end
    end
  end
  return rows
end

-- ]c / [c : jump to the next / previous cell (count-aware).
local function jump_cell(dir)
  local buf = vim.api.nvim_get_current_buf()
  local cur = vim.api.nvim_win_get_cursor(0)[1]
  local rows, target = cell_rows(buf), nil
  for _ = 1, math.max(vim.v.count, 1) do
    target = nil
    if dir > 0 then
      for _, r in ipairs(rows) do if r > cur then target = r; break end end
    else
      for i = #rows, 1, -1 do if rows[i] < cur then target = rows[i]; break end end
    end
    if not target then break end
    cur = target
  end
  if cur ~= vim.api.nvim_win_get_cursor(0)[1] then
    vim.cmd("normal! m'")
    vim.api.nvim_win_set_cursor(0, { cur, 0 })
    vim.cmd("normal! ^")
  end
end

-- io / ao : the result fence under the cursor (or under the trigger on the
-- cursor line). `io` = its body, `ao` = the whole fence. Linewise, so `yio`
-- copies a cell's output even while it's folded.
local function output_span(around)
  local buf = vim.api.nvim_get_current_buf()
  local open, close = fence.output_at(buf, vim.api.nvim_win_get_cursor(0)[1])
  if not open then return nil end
  if around then return open, close, open end
  if open + 1 > close - 1 then return nil end -- empty body
  return open + 1, close - 1, open
end

function M._select_output(around)
  local a, b, open = output_span(around)
  if not a then return end
  local buf = vim.api.nvim_get_current_buf()
  local visual = vim.fn.mode():match("[vV\22]")
  -- an operator takes a closed fold as a whole, so open it for the operator and
  -- close it again afterwards (if the fence is still there)
  if vim.fn.foldclosed(open) ~= -1 then
    vim.cmd(open .. "foldopen")
    if not visual then
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(buf) and fence.output_at(buf, open) == open then
          pcall(vim.cmd, open .. "foldclose")
        end
      end)
    end
  end
  if visual then vim.cmd("normal! \27") end
  vim.api.nvim_win_set_cursor(0, { a, 0 })
  vim.cmd("normal! V")
  vim.api.nvim_win_set_cursor(0, { b, 0 })
end

-- The `io`/`ao` mapping: select the span, or with none here cancel a pending
-- operator (and leave a visual selection as it is).
local function output_object(around)
  return function()
    if not output_span(around) then
      return vim.fn.mode(1):sub(1, 2) == "no" and "<Esc>" or ""
    end
    return "<Cmd>lua require('bsh')._select_output(" .. tostring(around) .. ")<CR>"
  end
end

-- <M-CR> on a one-line cell: run it, then open a fresh prompt with the same prefix
-- (`% `, `user@host%% `, `>> `...) one blank line below its output, in insert mode,
-- REPL style. Anywhere else it's what <CR> would be: a newline in insert mode, or
-- a plain run / cursor-down in normal mode.
local function run_and_continue(insert)
  local buf = vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
  local c = cell.parse(line)
  local prefix = c and (c.kind == "shell" or c.kind == "agent") and c.prefix
  if not prefix or input_fence_at(buf, row - 1) then
    if insert then
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "ni", false)
    elseif not execute_cell(false) then
      vim.cmd("normal! +")
    end
    return
  end
  if not execute_cell(false) then return end
  local indent = line:match("^(%s*)")
  local _, stop = fence_range(buf, row - 1, indent, "out") -- [start, stop), 0-indexed
  vim.api.nvim_buf_set_lines(buf, stop, stop, false, { "", prefix }) -- a blank line between cells
  vim.api.nvim_win_set_cursor(0, { stop + 2, #prefix })
  if not insert then vim.cmd("startinsert!") end
end

-- If the cursor sits on a persistent-session cell, return its { lang, target }.
-- Two cell shapes carry a session: a multiline input fence with the `%%` suffix
-- (```python %%```, ```%%```) and the inline doubled marker (`%% cmd`,
-- `user@host%% cmd`). Anything else (one-shots, prose, output fences) -> nil.
local function classify_session(buf, row)
  local fc = input_fence_at(buf, row)
  if fc and fc.session then return { lang = fc.lang, target = fc.target } end
  local c = cell.parse(vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or "")
  if c and c.kind == "shell" and c.session then return { lang = "sh", target = c.target } end
  return nil
end

local function session_label(c)
  return (c.target ~= "" and (c.target .. " ") or "") .. c.lang
end

-- Collect, in DOCUMENT ORDER, every session cell at or above `upto` whose
-- (lang, target) matches `want` -- the units that, replayed in sequence, rebuild
-- the state a far-down cell depends on. Two shapes carry a session: a ```lang %%``
-- input fence and an inline `%%`/`target%% cmd` line (always `sh`). We walk
-- top-down, skipping each fenced block as a whole (by its closing ```), so an
-- ```out result body that happens to contain a `%`-looking line is never mistaken
-- for a trigger. Each entry mirrors the args run_session takes.
local function collect_session_cells(buf, upto, want)
  local total = vim.api.nvim_buf_line_count(buf)
  local function gl(r) return vim.api.nvim_buf_get_lines(buf, r, r + 1, false)[1] or "" end
  local cells, r = {}, 0
  while r <= upto and r < total do
    local line = gl(r)
    if line:match("^%s*```%S") then
      -- an opening fence: find its closer and skip the whole block either way
      local close = total - 1
      for rr = r + 1, total - 1 do
        if gl(rr):match("^%s*```%s*$") then close = rr; break end
      end
      local lang, target, sess = parse_runmarker(vim.trim(line:match("^%s*```(.*)$") or ""), config.marker)
      if lang and sess and lang == want.lang and target == want.target then
        cells[#cells + 1] = {
          trow = close, prow = r, indent = line:match("^(%s*)"),
          cmd = table.concat(vim.api.nvim_buf_get_lines(buf, r + 1, close, false), "\n"),
        }
      end
      r = close + 1
    else
      -- an inline session line is always `sh`; only collect when that's wanted
      local c = cell.parse(line)
      if c and c.kind == "shell" and c.session and want.lang == "sh" and c.target == want.target then
        cells[#cells + 1] = { trow = r, prow = r, indent = c.indent, cmd = c.body }
      end
      r = r + 1
    end
  end
  return cells
end

-- :BshReplay / <localleader>r — replay this session from the top THROUGH the cell
-- under the cursor, into a FRESH interpreter. We reset the session first (so the
-- replay starts from clean state) then enqueue every matching cell in document
-- order; session.lua's FIFO pump runs them one after another, each filling its own
-- fence as it completes. The point: after a :BshReset (or reopening the file) a
-- far-down cell depends on imports/vars/`cd` from earlier cells that no longer
-- live in the interpreter -- this rebuilds them in one keystroke.
local function replay_session()
  local buf = vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local c = classify_session(buf, row)
  if not c then
    vim.notify("bsh: put the cursor on a session (%% / ```%% ) cell to replay", vim.log.levels.WARN)
    return
  end
  local cells = collect_session_cells(buf, row, c)
  if #cells == 0 then return end
  session.reset_session(buf, c.lang, c.target) -- replay into a clean interpreter
  for _, cell in ipairs(cells) do
    run_session(buf, c.lang, c.target, cell.trow, cell.indent, cell.cmd, false, cell.prow)
  end
  vim.notify(("bsh: replaying %d %s cell%s"):format(#cells, session_label(c), #cells == 1 and "" or "s"))
end

-- <C-c> / :BshCancel — cancel the running cell under the cursor. A one-shot
-- (`%`) is stopped outright; a session cell's running command is INTERRUPTED
-- (SIGINT) so the session itself survives. Falls back to the sole busy session in
-- the buffer when the cursor isn't on a recognisable cell.
local function cancel_here()
  local buf = vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  if job.cancel_at(buf, row) then return end
  local c = classify_session(buf, row)
  if c and session.interrupt_session(buf, c.lang, c.target) then
    vim.notify("bsh: interrupted " .. session_label(c) .. " session (SIGINT)")
    return
  end
  local busy = {}
  for _, s in ipairs(session.list_sessions(buf)) do if s.busy then busy[#busy + 1] = s end end
  if #busy == 1 and session.interrupt_session(buf, busy[1].lang, busy[1].target) then
    vim.notify("bsh: interrupted " .. session_label(busy[1]) .. " session (SIGINT)")
    return
  end
  vim.notify("bsh: no running cell under the cursor", vim.log.levels.WARN)
end

-- <localleader>R / :BshReset[!] — reset (restart) the session for the cell under
-- the cursor, so the next run gets a fresh interpreter. `!` resets every session
-- in the buffer. With one session and an ambiguous cursor we reset it anyway;
-- with several we refuse and point at `!` rather than guess.
local function reset_here(all)
  local buf = vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  if all then
    local n = session.reset_all(buf)
    vim.notify("bsh: reset " .. n .. " session" .. (n == 1 and "" or "s"))
    return
  end
  local c = classify_session(buf, row)
  if c and session.reset_session(buf, c.lang, c.target) then
    vim.notify("bsh: reset " .. session_label(c) .. " session")
    return
  end
  local list = session.list_sessions(buf)
  if #list == 0 then
    vim.notify("bsh: no session here", vim.log.levels.WARN)
  elseif #list == 1 then
    session.reset_session(buf, list[1].lang, list[1].target)
    vim.notify("bsh: reset " .. session_label(list[1]) .. " session")
  else
    vim.notify("bsh: multiple sessions — put the cursor on a session cell, or :BshReset! to reset all",
      vim.log.levels.WARN)
  end
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
    vim.opt_local.foldexpr = "v:lua.require'bsh'.foldexpr(v:lnum)"
    vim.opt_local.foldtext = "v:lua.require'bsh'.foldtext()"
    vim.opt_local.foldlevel = config.agent_hide_thinking and 1 or 99
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

  -- Visual <CR>: when the selection ENDS on an agent cell (`>`/`>>`), run it with
  -- the lines above it in the selection attached as context. Any other selection
  -- keeps the default <CR> motion.
  vim.keymap.set("x", "<CR>", function()
    local a, b = vim.fn.line("v"), vim.fn.line(".")
    local first, last = math.min(a, b), math.max(a, b)
    local trig = vim.api.nvim_buf_get_lines(buf, last - 1, last, false)[1] or ""
    local tc = cell.parse(trig)
    if first < last and tc and tc.kind == "agent" then
      attach_lines = vim.api.nvim_buf_get_lines(buf, first - 1, last - 1, false)
      vim.cmd("normal! \27")
      vim.api.nvim_win_set_cursor(0, { last, 0 })
      if not execute_cell(false) then attach_lines = nil end
    else
      vim.cmd("normal! +")
    end
  end, { buffer = buf, desc = "bsh: run the agent cell ending the selection, selection attached" })

  -- ]c / [c jump between cells; io / ao select a cell's output (yio, dao, vio).
  vim.keymap.set({ "n", "x", "o" }, "]c", function() jump_cell(1) end,
    { buffer = buf, desc = "bsh: next cell" })
  vim.keymap.set({ "n", "x", "o" }, "[c", function() jump_cell(-1) end,
    { buffer = buf, desc = "bsh: previous cell" })
  vim.keymap.set({ "x", "o" }, "io", output_object(false),
    { buffer = buf, expr = true, desc = "bsh: inner output (a result fence's body)" })
  vim.keymap.set({ "x", "o" }, "ao", output_object(true),
    { buffer = buf, expr = true, desc = "bsh: around output (the whole result fence)" })
  vim.keymap.set("i", "<M-CR>", function() run_and_continue(true) end,
    { buffer = buf, desc = "bsh: run this cell, then start the next one below it" })
  vim.keymap.set("n", "<M-CR>", function() run_and_continue(false) end,
    { buffer = buf, desc = "bsh: run this cell, then start the next one below it" })

  -- <C-c> cancels the running cell under the cursor (one-shot: stop; session:
  -- SIGINT the running command, keep the session). <C-k> ("kill") resets the
  -- session for the cell under the cursor (<C-k> has no default normal-mode
  -- meaning, unlike most ctrl keys). Both are also :BshCancel / :BshReset.
  vim.keymap.set("n", "<C-c>", cancel_here,
    { buffer = buf, desc = "bsh: cancel the running cell under the cursor" })
  vim.keymap.set("n", "<C-k>", function() reset_here(false) end,
    { buffer = buf, desc = "bsh: reset the session for the cell under the cursor" })
  vim.api.nvim_buf_create_user_command(buf, "BshCancel", function() cancel_here() end,
    { desc = "cancel the running cell under the cursor" })
  vim.api.nvim_buf_create_user_command(buf, "BshReset", function(o) reset_here(o.bang) end,
    { bang = true, desc = "reset the session for the cell under the cursor (! = all in buffer)" })

  -- <localleader>t / :BshThinking -- hide or show the agent's thinking lines (a
  -- fold level of 1 closes the nested thinking folds, 99 opens everything).
  local function toggle_thinking()
    vim.api.nvim_buf_call(buf, function()
      vim.opt_local.foldlevel = vim.wo.foldlevel < 99 and 99 or 1
    end)
  end
  vim.keymap.set("n", "<localleader>t", toggle_thinking,
    { buffer = buf, desc = "bsh: hide/show the agent's thinking" })
  vim.api.nvim_buf_create_user_command(buf, "BshThinking", toggle_thinking,
    { desc = "hide/show the agent's thinking lines" })

  vim.api.nvim_buf_create_user_command(buf, "BshForget", function()
    require("bsh.agent").forget(buf)
    vim.notify("bsh: the next `>>` starts a fresh conversation")
  end, { desc = "forget this file's `>>` conversation" })

  -- <localleader>r / :BshReplay — replay this session from the top through the
  -- cell under the cursor, into a fresh interpreter (resets first, then re-runs
  -- every matching session cell in document order).
  vim.keymap.set("n", "<localleader>r", replay_session,
    { buffer = buf, desc = "bsh: replay the session up to (and incl.) the cell under the cursor" })
  vim.api.nvim_buf_create_user_command(buf, "BshReplay", function() replay_session() end,
    { desc = "replay this session from the top through the cell under the cursor (fresh interpreter)" })

  -- optional: real LSP inside ```python fences via otter.nvim. No-op when otter
  -- isn't installed or config.otter is off (see lua/bsh/otter.lua).
  require("bsh.otter").activate(buf)
end

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
  -- files at the end of a route open as bsh://<route>:<path> buffers
  require("bsh.remote").setup()
  -- tear a buffer's persistent `%%` shell down when the buffer is wiped.
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

-- require("bsh").setup({ marker = "%", agent = "llm", ... }): merge options into
-- bsh.config. The plugin already wires itself up from plugin/bsh.lua, so this
-- only sets options (and is what lazy.nvim's `config = true` / `opts = {}` call).
-- Table options (e.g. `transports`) are merged, so adding one keeps the defaults.
function M.setup(opts)
  for k, v in pairs(opts or {}) do
    if config[k] == nil then
      vim.notify("bsh: unknown option '" .. tostring(k) .. "'", vim.log.levels.WARN)
    elseif type(v) == "table" and type(config[k]) == "table" and not vim.islist(v) then
      config[k] = vim.tbl_extend("force", config[k], v)
    else
      config[k] = v
    end
  end
  vim.env.BSH_MARKER = config.marker
  return M
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
