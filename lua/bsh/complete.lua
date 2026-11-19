-- Route-aware, on-request completion for shell cells. The candidates come from
-- wherever the cell RUNS: `% gi` completes commands from your local PATH,
-- `me@server% sq` from the server's (module-loaded PATH included), `docker@api%`
-- from inside the container. Paths complete in the cell's directory: the doc's
-- folder locally, $HOME at the end of a route, and for a `%%` session the
-- directory its shell is in right now (so after `cd /gpfs/projects`, that).
--
-- Nothing pops up while you type. Ask for it: <C-x><C-o> (omnifunc), <Tab> on a
-- shell line when nvim-cmp isn't installed, or nvim-cmp's own trigger (the `bsh`
-- source is added to bsh buffers automatically).
local M = {}

local cell = require("bsh.cell")
local config = require("bsh.config")
local job = require("bsh.job")
local util = require("bsh.util")

local MARK = "__BSH_COMPLETE__" -- output before it (login banners on stdout) is dropped
local CMD_TTL, FILE_TTL = 300, 5 -- seconds a cached command list / directory listing stays fresh
local MAX = 3000

-- ---------------------------------------------------------------------------
-- Where are we? Pure parsing, unit-tested.

-- What to complete on `line`, cursor at 0-indexed byte `col` (the text left of
-- the cursor is line:sub(1, col)), for a one-line `%` / `%%` cell. Returns
-- { target, session, word, start, first } (start = 0-indexed byte col where
-- `word` begins; first = it's in command position) or nil.
function M.line_context(line, col)
  -- parse with a stand-in body so a bare `% ` prompt still counts as a cell
  local c = cell.parse(line:sub(1, col) .. "x")
  if not (c and c.kind == "shell") then return nil end
  local plen = #c.prefix
  if col < plen then return nil end
  local ctx = M.word_context(line:sub(plen + 1, col))
  ctx.start = ctx.start + plen
  ctx.target, ctx.session = c.target, c.session
  return ctx
end

-- Split shell text left of the cursor into the word being typed and whether it
-- is in command position (start of the line, or after | ; & ( `).
function M.word_context(text)
  local word = text:match("([^%s|;&()<>`]*)$") or ""
  local before = text:sub(1, #text - #word)
  local first = before:match("^%s*$") ~= nil or before:match("[|;&(`]%s*$") ~= nil
  -- `sudo cmd`, `exec cmd`, ... keep command position
  if not first then
    local prev = before:match("(%S+)%s+$")
    first = prev == "sudo" or prev == "exec" or prev == "time" or prev == "nohup"
        or prev == "env" or prev == "xargs" or prev == "watch" or prev == "which"
        or prev == "command" or prev == "type" or prev == "man"
  end
  -- a word that looks like a path is a path even in command position (./run, ~/bin/x)
  if word:find("/") then first = false end
  return { word = word, start = #before, first = first }
end

-- The completion context at the cursor in `buf`: a one-line cell, or a line
-- inside a ```% / ```%% (shell) input fence. Adds `cwd` (see the header).
function M.context(buf, row, col)
  local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
  local ctx = M.line_context(line, col)
  if not ctx then
    local fc = require("bsh.cell").input_fence_at(buf, row)
    if not (fc and fc.lang == "sh" and row > fc.open and row < fc.close) then return nil end
    ctx = M.word_context(line:sub(1, col))
    ctx.target, ctx.session = fc.target, fc.session
  end
  if ctx.session then
    ctx.cwd = require("bsh.session").session_cwd(buf, "sh", ctx.target)
  end
  if not ctx.cwd and ctx.target == "" then ctx.cwd = job.doc_cwd(buf) end
  return ctx
end

-- ---------------------------------------------------------------------------
-- Fetching, over the route. One cached list per route for commands; one cached
-- listing per (route, cwd, directory) for paths, filtered locally as you type.

local cache = {}

local function run(target, cwd, script, cb)
  local cmd = "printf '%s\\n' " .. MARK .. "; " .. script
  -- locally the cwd is the job's own; over a route, cd there first
  if target ~= "" and cwd then cmd = "cd " .. util.qpath(cwd) .. " 2>/dev/null; " .. cmd end
  local ok, err = pcall(vim.system, job.build_argv(target, cmd),
    { cwd = target == "" and cwd or nil, text = true, timeout = 15000 },
    function(r)
      local lines, seen = {}, false
      for l in ((r.stdout or "") .. ""):gmatch("[^\r\n]+") do
        if seen then lines[#lines + 1] = l elseif l == MARK then seen = true end
      end
      vim.schedule(function() cb(lines) end)
    end)
  if not ok then
    vim.schedule(function()
      vim.notify("bsh: completion failed: " .. tostring(err), vim.log.levels.WARN)
      cb({})
    end)
  end
end

local function cached(key, ttl, fetch, cb)
  local hit = cache[key]
  if hit and hit.lines and os.time() - hit.at < ttl then return cb(hit.lines) end
  if hit and hit.waiting then -- a fetch is already out: join it
    table.insert(hit.waiting, cb); return
  end
  hit = { waiting = { cb } }
  cache[key] = hit
  fetch(function(lines)
    hit.lines, hit.at = lines, os.time()
    local w = hit.waiting
    hit.waiting = nil
    for _, f in ipairs(w) do f(lines) end
  end)
end

-- Every command name the route's shell knows (bash's compgen; a PATH scan
-- where there is no bash).
local CMDS_SH = [[if command -v bash >/dev/null 2>&1; then bash -c 'compgen -c' 2>/dev/null
else IFS=:; for d in $PATH; do ls -1 "$d" 2>/dev/null; done; fi]]

local function commands(target, cb)
  cached("c\0" .. target, CMD_TTL, function(done)
    run(target, nil, CMDS_SH, function(lines)
      local seen, out = {}, {}
      for _, l in ipairs(lines) do
        if not seen[l] and l ~= "" then
          seen[l] = true; out[#out + 1] = l
        end
      end
      table.sort(out)
      done(out)
    end)
  end, cb)
end

-- The entries of `dir` (a word's directory part, "" = cwd), dirs marked with /.
local function listing(target, cwd, dir, cb)
  local path = dir == "" and "." or dir
  cached(table.concat({ "f", target, cwd or "", path }, "\0"), FILE_TTL, function(done)
    run(target, cwd, "ls -1Ap -- " .. util.qpath(path) .. " 2>/dev/null", done)
  end, cb)
end

-- The candidates for `ctx` (from M.context): cb({ { word, kind } ... }), kind =
-- "command" | "dir" | "file".
function M.candidates(ctx, cb)
  local word = ctx.word
  if ctx.first then
    return commands(ctx.target, function(cmds)
      local out = {}
      for _, c in ipairs(cmds) do
        if vim.startswith(c, word) then
          out[#out + 1] = { word = c, kind = "command" }
          if #out >= MAX then break end
        end
      end
      cb(out)
    end)
  end
  local dir, base = word:match("^(.*/)(.-)$")
  if not dir then dir, base = "", word end
  listing(ctx.target, ctx.cwd, dir, function(entries)
    local out = {}
    for _, e in ipairs(entries) do
      -- dotfiles only once you've typed the dot, like a shell
      if vim.startswith(e, base) and (base:sub(1, 1) == "." or e:sub(1, 1) ~= ".") then
        out[#out + 1] = { word = dir .. e, kind = e:sub(-1) == "/" and "dir" or "file" }
        if #out >= MAX then break end
      end
    end
    cb(out)
  end)
end

-- Drop cached lists (all, or one route's), e.g. after installing something.
function M.clear(target)
  if not target then
    cache = {}; return
  end
  for k in pairs(cache) do
    if k:find("\0" .. target, 1, true) then cache[k] = nil end
  end
end

-- ---------------------------------------------------------------------------
-- Front ends.

local KIND_LABEL = { command = "cmd", dir = "dir", file = "file" }

-- 'omnifunc' (<C-x><C-o>). Blocks for the fetch (a cache hit is instant; a
-- route round-trip is one ssh call, fast with ControlMaster). Off a shell line
-- it defers to LSP's omnifunc, so ```python fences with otter keep theirs.
local pending -- the context found by the findstart call
function M.omnifunc(findstart, base)
  local buf = vim.api.nvim_get_current_buf()
  if findstart == 1 then
    local pos = vim.api.nvim_win_get_cursor(0)
    pending = M.context(buf, pos[1] - 1, pos[2])
    if not pending then
      if next(vim.lsp.get_clients({ bufnr = buf })) then return vim.lsp.omnifunc(1, base) end
      return -3 -- not here: leave completion mode quietly
    end
    return pending.start
  end
  if not pending then return vim.lsp.omnifunc(0, base) end
  local ctx = vim.tbl_extend("force", pending, { word = base })
  pending = nil
  local result, done = {}, false
  M.candidates(ctx, function(items)
    result, done = items, true
  end)
  vim.wait(15000, function() return done end, 20)
  local out = {}
  for _, it in ipairs(result) do
    out[#out + 1] = { word = it.word, menu = KIND_LABEL[it.kind], kind = it.kind:sub(1, 1) }
  end
  return out
end

-- nvim-cmp source. Registered once, then appended to each bsh buffer's sources
-- (keeping the user's, in the first group), so cmp's own trigger and settings
-- apply -- with `autocomplete = false` it only shows when you ask.
local cmp_source = {}
cmp_source.new = function() return setmetatable({}, { __index = cmp_source }) end
function cmp_source:get_debug_name() return "bsh" end

function cmp_source:is_available()
  local pos = vim.api.nvim_win_get_cursor(0)
  return M.context(vim.api.nvim_get_current_buf(), pos[1] - 1, pos[2]) ~= nil
end

-- shell words: anything up to a blank or a shell metachar
function cmp_source:get_keyword_pattern() return [[\%([^[:blank:]|;&()<>`]\)*]] end

function cmp_source:complete(params, callback)
  local buf = vim.api.nvim_get_current_buf()
  local row = params.context.cursor.row - 1
  local col = params.context.cursor.col - 1
  local ctx = M.context(buf, row, col)
  if not ctx then return callback({ items = {}, isIncomplete = false }) end
  local K = require("cmp").lsp.CompletionItemKind
  local KIND = { command = K.Function, dir = K.Folder, file = K.File }
  M.candidates(ctx, function(items)
    local out = {}
    for _, it in ipairs(items) do
      -- cmp replaces the word matched by get_keyword_pattern (same split as ours)
      out[#out + 1] = { label = it.word, insertText = it.word, filterText = it.word, kind = KIND[it.kind] }
    end
    callback({ items = out, isIncomplete = false })
  end)
end

local cmp_registered = false
local function setup_cmp(buf)
  local ok, cmp = pcall(require, "cmp")
  if not ok then return false end
  if not cmp_registered then
    cmp.register_source("bsh", cmp_source.new())
    cmp_registered = true
  end
  vim.api.nvim_buf_call(buf, function()
    local srcs = vim.deepcopy(cmp.get_config().sources or {})
    for _, s in ipairs(srcs) do if s.name == "bsh" then return end end
    table.insert(srcs, 1, { name = "bsh", group_index = srcs[1] and srcs[1].group_index or nil })
    cmp.setup.buffer({ sources = srcs })
  end)
  return true
end

-- Wire completion into `buf` (called from bsh.attach).
function M.attach(buf)
  if config.complete == false then return end
  vim.bo[buf].omnifunc = "v:lua.require'bsh.complete'.omnifunc"
  if package.loaded.cmp and setup_cmp(buf) then return end
  -- nvim-cmp is often lazy-loaded on InsertEnter: wire it up on the first one,
  -- synchronously (requiring it loads it), so a <Tab> typed straight after
  -- entering insert mode already finds the source.
  vim.api.nvim_create_autocmd("InsertEnter", {
    buffer = buf,
    once = true,
    callback = function()
      if setup_cmp(buf) then return end
      -- no cmp: <Tab> on a shell line asks for completion; a plain Tab elsewhere
      vim.keymap.set("i", "<Tab>", function()
        if vim.fn.pumvisible() == 1 then return "<C-n>" end
        local pos = vim.api.nvim_win_get_cursor(0)
        if M.context(buf, pos[1] - 1, pos[2]) then return "<C-x><C-o>" end
        return "<Tab>"
      end, { buffer = buf, expr = true, desc = "bsh: complete from where this cell runs" })
    end,
  })
end

return M
