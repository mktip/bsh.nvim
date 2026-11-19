-- Moving around and editing a cell document: ]c / [c between cells, the io / ao
-- output text objects, and opening a new prompt below a cell (<M-CR>, history).
local M = {}

local cell = require("bsh.cell")
local config = require("bsh.config")
local fence = require("bsh.fence")
local util = require("bsh.util")

-- Is `line` (outside any fence) a cell trigger? `nxt` is the line below it: any
-- line that already owns a result fence counts, which covers `name.space` cells.
local function is_trigger(line, nxt)
  local tag = (nxt or ""):match("^%s*```(%S+)%s*$")
  if tag and fence.OWNED_TAGS[tag] then return true end
  if cell.rule_for(line) then return true end
  local c = cell.parse(line)
  if c and c.kind ~= "ns" and c.kind ~= "nsedit" then return true end -- ns: only with a fence
  local info = line:match("^%s*```(.+)$")
  return info ~= nil and util.parse_runmarker(vim.trim(info), config.marker) ~= nil
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
function M.jump_cell(dir)
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

function M.select_output(around)
  local a, b, open = output_span(around)
  if not (a and open) then return end
  local buf = vim.api.nvim_get_current_buf()
  local visual = vim.fn.mode():match("[vV\22]")
  -- an operator takes a closed fold as a whole, so open it for the operator and
  -- close it again afterwards (if the fence is still there)
  if vim.fn.foldclosed(open) ~= -1 then
    vim.cmd(open .. "foldopen")
    if not visual then
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(buf) and fence.output_at(buf, open) == open then
          pcall(function() vim.cmd(open .. "foldclose") end)
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
function M.output_object(around)
  return function()
    if not output_span(around) then
      return vim.fn.mode(1):sub(1, 2) == "no" and "<Esc>" or ""
    end
    return "<Cmd>lua require('bsh.edit').select_output(" .. tostring(around) .. ")<CR>"
  end
end

-- The prompt prefix (`% `, `user@host%% `, a rule's own like `>> `) of the
-- one-line cell on 1-indexed `row`, or nil.
function M.prompt_prefix(buf, row)
  if cell.input_fence_at(buf, row - 1) then return nil end
  local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
  local rule = cell.rule_for(line)
  if rule then return rule.prompt and rule.prompt(line) or nil end
  local c = cell.parse(line)
  return c and c.kind == "shell" and c.prefix or nil
end

-- Open a fresh prompt `prefix` (followed by `text`, if given) one blank line
-- below the output of the cell on 1-indexed `trow` (just below the trigger if it
-- has none yet), in insert mode.
function M.open_prompt_below(buf, trow, prefix, text)
  local line = vim.api.nvim_buf_get_lines(buf, trow - 1, trow, false)[1] or ""
  local _, stop = fence.fence_range(buf, trow - 1, line:match("^(%s*)"), "out") -- [start, stop), 0-indexed
  local new = prefix .. (text or "")
  vim.api.nvim_buf_set_lines(buf, stop, stop, false, { "", new }) -- a blank line between cells
  vim.api.nvim_win_set_cursor(0, { stop + 2, #new })
  if vim.fn.mode() ~= "i" then vim.cmd("startinsert!") end
end

return M
