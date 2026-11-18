-- Per-route command history. Two sources, newest first:
--   1. what you ran through bsh on that route (any file), recorded on every
--      one-line shell cell, one file per route under stdpath("state")/bsh/history;
--   2. that machine's own shell history (~/.bash_history, zsh's, fish's), read
--      over the route once per Neovim session -- so on a cluster you also get what
--      you typed there in a plain terminal.
-- Route aliases are resolved first, so `box%` and `me@server%` share a history.
local M = {}

local config = require("bsh.config")
local job = require("bsh.job")

local MARK = "__BSH_HISTORY__"

local function key(target)
  local k = job.expand_route(target or "")
  return k == "" and "local" or k
end
M.key = key

local function dir()
  return config.history_dir or (vim.fn.stdpath("state") .. "/bsh/history")
end

local function file(target)
  -- one flat file per route; `/`, `@` and friends are percent-encoded
  return dir() .. "/" .. key(target):gsub("[^%w%._-]", function(c)
    return string.format("%%%02X", c:byte())
  end)
end

local function read_lines(path)
  local f = io.open(path, "r")
  if not f then return {} end
  local t = {}
  for l in f:lines() do t[#t + 1] = vim.trim(l) end
  f:close()
  return t
end

-- newest-first, duplicates dropped (the newest occurrence wins)
local function newest_first(oldest_first, seen, out)
  seen, out = seen or {}, out or {}
  for i = #oldest_first, 1, -1 do
    local l = oldest_first[i]
    if l ~= "" and not seen[l] then
      seen[l] = true; out[#out + 1] = l
    end
  end
  return out, seen
end

-- What bsh itself recorded for `target`, newest first.
function M.own(target)
  return (newest_first(read_lines(file(target))))
end

-- Record `cmd` as run on `target`. Keeps the file to config.history_max
-- entries (rewritten, deduplicated, once it grows past twice that).
function M.add(target, cmd)
  if config.history == false then return end
  cmd = vim.trim(cmd or "")
  if cmd == "" or cmd:find("\n") then return end
  vim.fn.mkdir(dir(), "p")
  local path = file(target)
  local f = io.open(path, "a")
  if not f then return end
  f:write(cmd, "\n")
  f:close()
  local max = config.history_max or 5000
  if vim.fn.getfsize(path) > max * 2 * 40 then -- cheap size check before counting
    local lines = read_lines(path)
    if #lines > max * 2 then
      local keep = newest_first(lines)
      local out = {}
      for i = math.min(#keep, max), 1, -1 do out[#out + 1] = keep[i] end
      local w = io.open(path, "w")
      if w then
        w:write(table.concat(out, "\n"), "\n"); w:close()
      end
    end
  end
end

-- Pull the plain commands out of a shell history file (oldest first): zsh's
-- extended `: <ts>:<d>;cmd`, fish's `- cmd: ...`, bash's `#<ts>` stamp lines.
function M.parse_shell_history(lines)
  local out = {}
  for _, l in ipairs(lines) do
    local cmd = l:match("^: %d+:%d+;(.*)$") or l:match("^%- cmd: (.*)$")
    if not cmd then
      if l:match("^#%d+$") or l:match("^%s+when: %d+") or l:match("^%s+paths:")
          or l:match("^%s+%- ") then
        cmd = nil
      else
        cmd = l
      end
    end
    -- multi-line commands (trailing \) aren't something a one-line cell can hold
    cmd = cmd and vim.trim(cmd)
    if cmd and cmd ~= "" and not cmd:match("\\$") then out[#out + 1] = cmd end
  end
  return out
end

local SHELL_HIST = [[case "${SHELL##*/}" in
  zsh) f=${HISTFILE:-${ZDOTDIR:-$HOME}/.zsh_history};;
  fish) f=${XDG_DATA_HOME:-$HOME/.local/share}/fish/fish_history;;
  *) f=${HISTFILE:-$HOME/.bash_history};;
esac
printf '%s\n' ]] .. MARK .. [[; [ -r "$f" ] && tail -n 5000 "$f"]]

local shell_cache = {} -- [key] = list (newest first) | { waiting = {cb...} }

-- The machine's own shell history for `target`, newest first, via cb (async;
-- fetched once per session per route).
function M.shell(target, cb)
  if config.history_shell == false then return cb({}) end
  local k = key(target)
  local hit = shell_cache[k]
  if hit and hit.list then return cb(hit.list) end
  if hit then
    table.insert(hit.waiting, cb); return
  end
  hit = { waiting = { cb } }
  shell_cache[k] = hit
  local function done(list)
    hit.list = list
    local w = hit.waiting
    hit.waiting = nil
    for _, f in ipairs(w) do f(list) end
  end
  local ok = pcall(vim.system, job.build_argv(target or "", SHELL_HIST),
    { text = true, timeout = 15000, stdin = false },
    function(r)
      local lines, seen = {}, false
      for l in (r.stdout or ""):gmatch("[^\r\n]+") do
        if seen then lines[#lines + 1] = l elseif l == MARK then seen = true end
      end
      local list = newest_first(M.parse_shell_history(lines))
      vim.schedule(function() done(list) end)
    end)
  if not ok then vim.schedule(function() done({}) end) end
end

-- Everything for `target`, newest first: bsh's own record, then the shell's.
-- cb(list, final): called right away with what's at hand, and -- if the shell
-- history still has to be fetched -- again with the full list (final = true).
function M.entries(target, cb)
  local own = M.own(target)
  local got = false
  M.shell(target, function(sh)
    local seen = {}
    for _, l in ipairs(own) do seen[l] = true end
    local all = vim.list_extend({}, own)
    for _, l in ipairs(sh) do
      if not seen[l] then
        seen[l] = true; all[#all + 1] = l
      end
    end
    got = true
    cb(all, true)
  end)
  if not got then cb(own, false) end
end

function M._reset_cache() shell_cache = {} end

-- ---------------------------------------------------------------------------
-- Recall in place: <C-p> / <C-n> on a prompt line (insert mode).

local hintns = vim.api.nvim_create_namespace("bsh_history")
local state = {} -- [buf] = { row, prefix, typed, orig, idx, list, loading, shown }

-- The one-line shell cell on `line` as (prefix, body), body "" for a bare `% `.
local function prompt_parts(line)
  local cell = require("bsh.cell")
  local c = cell.parse(line)
  if c and c.kind == "shell" then return c.prefix, line:sub(#c.prefix + 1), c.target end
  c = cell.parse(line .. "x")
  if c and c.kind == "shell" and c.body == "x" then return c.prefix, line:sub(#c.prefix + 1), c.target end
end

local function hint(buf, row, text)
  vim.api.nvim_buf_clear_namespace(buf, hintns, 0, -1)
  if text and text ~= "" then
    pcall(vim.api.nvim_buf_set_extmark, buf, hintns, row, 0,
      { virt_text = { { "  " .. text, "Comment" } }, virt_text_pos = "eol" })
  end
end

local function forget(buf)
  state[buf] = nil
  if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_clear_namespace(buf, hintns, 0, -1) end
end

local function matches(st)
  local out = {}
  for _, l in ipairs(st.list) do
    if l ~= st.typed and vim.startswith(l, st.typed) then out[#out + 1] = l end
  end
  return out
end

local function show(buf, st)
  local m = matches(st)
  if st.idx > #m then st.idx = #m end
  local line = st.idx == 0 and st.orig or (st.prefix .. m[st.idx])
  vim.api.nvim_buf_set_lines(buf, st.row, st.row + 1, false, { line })
  vim.api.nvim_win_set_cursor(0, { st.row + 1, #line })
  st.shown = line
  local more = st.loading and " …" or ""
  if #m == 0 then
    hint(buf, st.row, (st.loading and "loading history…" or ("no history" .. (st.typed ~= "" and (" for '" .. st.typed .. "'") or ""))))
  elseif st.idx == 0 then
    hint(buf, st.row, #m .. " in history" .. more)
  else
    hint(buf, st.row, st.idx .. "/" .. #m .. more)
  end
end

-- Step through the history of the prompt under the cursor: +1 older, -1 newer
-- (0 = what you had typed). Filtered by the text left of the cursor when you
-- started. Returns false when the cursor isn't on a prompt line.
function M.cycle(step)
  local buf = vim.api.nvim_get_current_buf()
  local pos = vim.api.nvim_win_get_cursor(0)
  local row, col = pos[1] - 1, pos[2]
  local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
  local st = state[buf]
  if not (st and st.row == row and st.shown == line) then
    local prefix, _, target = prompt_parts(line)
    if not prefix or col < #prefix then return false end
    if require("bsh")._input_fence_at(buf, row) then return false end
    st = { row = row, prefix = prefix, typed = line:sub(#prefix + 1, col), orig = line,
      idx = 0, list = {}, loading = true }
    state[buf] = st
    local sync = true
    M.entries(target, function(list, final)
      st.list, st.loading = list, not final
      -- the shell's history arrived later: refresh the hint (and the line, if
      -- you were waiting on an empty list)
      if not sync and state[buf] == st and vim.api.nvim_get_current_buf() == buf then
        if st.waiting and #matches(st) > 0 then st.idx = 1 end
        st.waiting = nil
        show(buf, st)
      end
    end)
    sync = false
  end
  st.idx = math.max(0, st.idx + step)
  -- asked for an older one while the list is still empty and loading: fill it in on arrival
  st.waiting = step > 0 and st.loading and #matches(st) == 0 or nil
  show(buf, st)
  return true
end

-- ---------------------------------------------------------------------------
-- :BshHistory -- the route's history as a buffer, newest at the bottom. Search
-- it however you like; <CR> puts a line into the prompt you came from.

function M.browse()
  local obuf, owin = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  local orow = vim.api.nvim_win_get_cursor(0)[1]
  local oline = vim.api.nvim_buf_get_lines(obuf, orow - 1, orow, false)[1] or ""
  local prefix, _, target = prompt_parts(oline)
  local trow = orow
  if not prefix then -- inside a shell cell's output: that cell's route
    local open = require("bsh.fence").output_at(obuf, orow)
    if open and open > 1 then
      local p, _, t = prompt_parts(vim.api.nvim_buf_get_lines(obuf, open - 2, open - 1, false)[1] or "")
      if p then target, trow = t, open - 1 end
    end
  end
  target = target or ""
  local on_prompt = prefix ~= nil

  local hbuf = vim.api.nvim_create_buf(false, true)
  vim.bo[hbuf].bufhidden = "wipe"
  pcall(vim.api.nvim_buf_set_name, hbuf, "bsh-history://" .. key(target))
  vim.cmd("botright 12split")
  local hwin = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(hwin, hbuf)
  vim.bo[hbuf].filetype = "sh"

  local function fill(list)
    if not vim.api.nvim_buf_is_valid(hbuf) then return end
    local lines = {}
    for i = #list, 1, -1 do lines[#lines + 1] = list[i] end
    if #lines == 0 then lines = { "" } end
    local at_end = vim.api.nvim_win_is_valid(hwin)
        and vim.api.nvim_win_get_cursor(hwin)[1] == vim.api.nvim_buf_line_count(hbuf)
    vim.api.nvim_buf_set_lines(hbuf, 0, -1, false, lines)
    if at_end and vim.api.nvim_win_is_valid(hwin) then
      vim.api.nvim_win_set_cursor(hwin, { #lines, 0 })
    end
  end
  M.entries(target, function(list) fill(list) end)

  vim.keymap.set("n", "q", "<Cmd>close<CR>", { buffer = hbuf, nowait = true })
  vim.keymap.set("n", "<CR>", function()
    local text = vim.api.nvim_get_current_line()
    vim.api.nvim_win_close(hwin, true)
    if text == "" or not vim.api.nvim_win_is_valid(owin) then return end
    vim.api.nvim_set_current_win(owin)
    local cur = vim.api.nvim_buf_get_lines(obuf, orow - 1, orow, false)[1] or ""
    if on_prompt and cur == oline then -- replace the prompt's command
      vim.api.nvim_buf_set_lines(obuf, orow - 1, orow, false, { prefix .. text })
      vim.api.nvim_win_set_cursor(owin, { orow, #prefix + #text })
      vim.cmd("startinsert!")
    else -- a new prompt on that route, below the cell (or the cursor line)
      require("bsh")._open_prompt_below(obuf, trow, target .. config.marker .. " ", text)
    end
  end, { buffer = hbuf, desc = "bsh: use this command" })
end

-- Wire the keys into `buf` (called from bsh.attach).
function M.attach(buf)
  if config.history == false then return end
  local function key_for(step, native)
    return function()
      if vim.fn.pumvisible() == 1 then
        return vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(native, true, false, true), "ni", false)
      end
      local ok, cmp = pcall(function() return package.loaded.cmp end)
      if ok and cmp and cmp.visible() then
        return step > 0 and cmp.select_prev_item() or cmp.select_next_item()
      end
      if not M.cycle(step) then
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(native, true, false, true), "ni", false)
      end
    end
  end
  vim.keymap.set("i", "<C-p>", key_for(1, "<C-p>"), { buffer = buf, desc = "bsh: older command from this route's history" })
  vim.keymap.set("i", "<C-n>", key_for(-1, "<C-n>"), { buffer = buf, desc = "bsh: newer command from this route's history" })
  vim.keymap.set("n", "<localleader>h", M.browse, { buffer = buf, desc = "bsh: this route's command history" })
  vim.api.nvim_buf_create_user_command(buf, "BshHistory", function() M.browse() end,
    { desc = "this route's command history, as a buffer" })
  -- editing the line yourself (or leaving insert mode) ends the walk
  local group = vim.api.nvim_create_augroup("bsh_history_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd("InsertLeave", { group = group, buffer = buf, callback = function() forget(buf) end })
  vim.api.nvim_create_autocmd("TextChangedI", {
    group = group, buffer = buf,
    callback = function()
      local st = state[buf]
      if st and (vim.api.nvim_buf_get_lines(buf, st.row, st.row + 1, false)[1] or "") ~= st.shown then
        forget(buf)
      end
    end,
  })
end

return M
