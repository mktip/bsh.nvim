-- The owned-fence + extmark substrate. A cell's result lives in a fence THIS
-- module stages and rewrites; the body is anchored by an extmark so async output
-- lands in the right place even as the buffer shifts. Also owns the shared
-- `ns` (extmark namespace) and `inflight` (per-buffer running jobs) state and the
-- folding expr/text. Everything higher up builds on this.
local M = {}

M.ns = vim.api.nvim_create_namespace("bsh")
local ns = M.ns

-- in-flight shell jobs, keyed by buffer then by the body extmark id, so a cell
-- re-run can cancel its own still-running job before staging a fresh fence.
M.inflight = {}
local inflight = M.inflight

-- Marks the user explicitly CANCELLED (via <C-c>/:BshCancel). The job's on_exit
-- consults this so a cancelled run renders `[cancelled]` (keeping whatever it had
-- already streamed) instead of a bare `[exit 143]`. Keyed buffer -> set of marks;
-- `take_` is one-shot so each cancellation is consumed exactly once.
M.cancelled = {}
function M.set_cancelled(buf, mark)
  M.cancelled[buf] = M.cancelled[buf] or {}
  M.cancelled[buf][mark] = true
end

function M.take_cancelled(buf, mark)
  local c = M.cancelled[buf]
  if c and c[mark] then
    c[mark] = nil; return true
  end
  return false
end

-- Locate (or plan the insertion of) the result fence that belongs to the
-- trigger on 0-indexed row `trow`. The owned fence must begin on the very next
-- line as `<indent>```<tag>` (tag is "out" for shell, "dir" for listings).
-- Returns the inclusive 0-indexed row range [start, stop) currently occupied by
-- a fence (empty range = none yet, insert a fresh one right after the trigger).
local OWNED_TAGS = { out = true, dir = true, tree = true, agent = true, log = true, menu = true }
M.OWNED_TAGS = OWNED_TAGS
function M.fence_range(buf, trow, indent, tag)
  local open = trow + 1
  local total = vim.api.nvim_buf_line_count(buf)
  if open >= total then return open, open end
  local l = vim.api.nvim_buf_get_lines(buf, open, open + 1, false)[1] or ""
  -- Match ANY owned tag, not just `tag`: when a trigger's output changes kind
  -- (e.g. an `out` cell edited into a `dir` listing) the existing fence must be
  -- recognised as ours and REPLACED, not left orphaned above the new one.
  local existing = l:match("^%s*```(%S+)%s*$")
  if not (existing and OWNED_TAGS[existing]) then return open, open end
  -- found an owned opening fence; scan for its closing ```
  for r = open + 1, total - 1 do
    local ll = vim.api.nvim_buf_get_lines(buf, r, r + 1, false)[1] or ""
    if ll:match("^%s*```%s*$") then return open, r + 1 end
  end
  -- unterminated fence: treat just the opening line as the region
  return open, open + 1
end

-- Cancel any still-running job whose body anchor lives in rows [start, stop)
-- (its on_exit becomes a no-op once its mark is gone) and drop those marks.
function M.clear_inflight(buf, start, stop)
  inflight[buf] = inflight[buf] or {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, { start, 0 }, { stop, -1 }, {})) do
    local id, job = m[1], inflight[buf][m[1]]
    if job then
      pcall(vim.fn.jobstop, job)
      inflight[buf][id] = nil
    end
    pcall(vim.api.nvim_buf_del_extmark, buf, ns, id)
  end
end

-- Replace rows [start, stop) with { open, placeholder, close } and return an
-- extmark anchoring the START of the body, so the async result lands exactly
-- there even if the buffer shifts meanwhile. LEFT gravity (right_gravity=false)
-- so that when streaming repaints the body via set_lines over [mark, mark+n),
-- the mark stays pinned at the body's top instead of being pushed below it.
function M.stage_block(buf, start, stop, open, placeholder, close)
  M.clear_inflight(buf, start, stop)
  vim.api.nvim_buf_set_lines(buf, start, stop, false, { open, placeholder, close })
  return vim.api.nvim_buf_set_extmark(buf, ns, start + 1, 0, { right_gravity = false })
end

-- Drop a fresh `<tag>` fence with a placeholder body in place of any existing one.
function M.stage_fence(buf, trow, indent, tag, placeholder)
  local start, stop = M.fence_range(buf, trow, indent, tag)
  return M.stage_block(buf, start, stop,
    indent .. "```" .. tag, indent .. placeholder, indent .. "```")
end

-- Replace the placeholder body (located via its extmark) with `lines`, each
-- indented to match the trigger. The closing fence below it is untouched. `n` is
-- how many body lines are there now: 1 (the placeholder) unless output was
-- streamed in; it may be a function, resolved when the fill actually runs, so a
-- caller whose streamed paints are still queued sees their final count.
function M.fill_fence(buf, mark, indent, lines, n)
  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(buf) then return end
    local pos = vim.api.nvim_buf_get_extmark_by_id(buf, ns, mark, {})
    if not pos[1] then return end
    local row = pos[1]
    local out = {}
    for _, l in ipairs(#lines > 0 and lines or { "(no output)" }) do
      out[#out + 1] = indent .. l
    end
    if type(n) == "function" then n = n() end
    vim.api.nvim_buf_set_lines(buf, row, row + (n or 1), false, out)
    pcall(vim.api.nvim_buf_del_extmark, buf, ns, mark)
    if inflight[buf] then
      inflight[buf][mark] = nil
    end
  end)
end

-- Inline output is capped at config.output_max_lines: keep the head, then one note
-- saying how much was left out (`more` = lines already dropped upstream, if any).
function M.cap_note(n)
  return "[... " .. n .. " more line" .. (n == 1 and "" or "s") .. " not shown; g<CR> runs it into a side buffer]"
end

function M.cap(lines, more)
  local max = require("bsh.config").output_max_lines
  more = more or 0
  if max and max > 0 and #lines > max then
    more = more + #lines - max
    for i = #lines, max + 1, -1 do lines[i] = nil end
  end
  if more > 0 then lines[#lines + 1] = M.cap_note(more) end
  return lines
end

-- The owned result fence at 1-indexed `row`: the one the cursor is in (delimiters
-- included), or the one right below a trigger line. Returns its 1-indexed
-- open/close rows, or nil. Used by the `io` / `ao` text objects.
local OWNED_OPEN = "^%s*```(%S+)%s*$"
function M.output_at(buf, row)
  local function gl(r) return vim.api.nvim_buf_get_lines(buf, r - 1, r, false)[1] or "" end
  local total = vim.api.nvim_buf_line_count(buf)
  local function closer(open)
    for r = open + 1, total do
      if gl(r):match("^%s*```%s*$") then return r end
    end
  end
  local function owned(r)
    local tag = gl(r):match(OWNED_OPEN)
    return tag and OWNED_TAGS[tag]
  end
  if row < total and owned(row + 1) and not owned(row) then -- on the trigger
    local c = closer(row + 1)
    if c then return row + 1, c end
  end
  for r = row, 1, -1 do
    local l = gl(r)
    if owned(r) then
      local c = closer(r)
      if c and c >= row then return r, c end
      return nil
    end
    if r < row and l:match("^%s*```%s*$") then return nil end -- below a closed fence
    if r < row and l:match("^%s*```%S") then return nil end   -- inside some other fence
  end
end

-- Folding: each fence (opening line through its closing ```) is its OWN fold;
-- the trigger line and surrounding prose stay at level 0 and visible.
-- We force a fold boundary at every fence so that ADJACENT fences with no blank
-- line between them -- e.g. a multiline input fence's closing ``` immediately
-- followed by the ```out result opener -- become two separate folds instead of
-- one merged blob. `>1` starts a fold at an opening fence, `<1` ends it at the
-- closing ```; content scans upward to decide inside (1) vs prose (0).
local OPEN = "^%s*```%S"
local FENCE = "^%s*```%s*$"

-- A run of agent "thinking" lines (they start with config.agent_thinking_prefix)
-- inside a fence is its own nested fold, level 2: a foldlevel of 1 hides the
-- thinking and leaves every fence open (see bsh.toggle_thinking).
local function is_thinking(line)
  local pre = require("bsh.config").agent_thinking_prefix
  return pre ~= "" and line:sub(1, #pre) == pre
end

function M.foldexpr(lnum)
  local line = vim.fn.getline(lnum)
  if line:match(OPEN) then return ">1" end   -- opener starts a fold
  if line:match(FENCE) then return "<1" end -- closer ends it
  for l = lnum - 1, 1, -1 do
    local s = vim.fn.getline(l)
    if s:match(OPEN) then -- inside a body
      if is_thinking(line) then return is_thinking(vim.fn.getline(lnum - 1)) and "2" or ">2" end
      return "1"
    end
    if s:match(FENCE) then return "0" end -- a closer above
  end
  return "0"
end

-- Collapsed cells read as `  + out (N lines)` / `  + dir (N entries)`
-- (N = body lines, fences excluded; tag taken from the opening fence).
function M.foldtext()
  local open = vim.fn.getline(vim.v.foldstart)
  local indent = open:match("^(%s*)")
  if is_thinking(open) then -- a nested run of thinking lines
    local k = vim.v.foldend - vim.v.foldstart + 1
    return indent .. "+ thinking (" .. k .. (k == 1 and " line)" or " lines)")
  end
  local tag = open:match("```(%S+)") or "out"
  local n = vim.v.foldend - vim.v.foldstart - 1
  local unit
  if tag == "dir" or tag == "tree" then
    unit = n == 1 and " entry)" or " entries)"
  elseif tag == "menu" then
    unit = n == 1 and " item)" or " items)"
  else
    unit = n == 1 and " line)" or " lines)"
  end
  return indent .. "+ " .. tag .. " (" .. n .. unit
end

return M
