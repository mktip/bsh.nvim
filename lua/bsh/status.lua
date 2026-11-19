-- How long a cell took and how it ended, as dim text at the end of its trigger
-- line: `running 4s…` while it runs (from the first second), then `1.3s · ok`
-- or `0.2s · exit 1`. Virtual text only: nothing is written into the file, and
-- it's gone when you reopen it. config.status = false turns it off.
local M = {}

local ns = vim.api.nvim_create_namespace("bsh_status")
M.ns = ns

local function fmt(sec)
  if sec < 10 then return string.format("%.1fs", sec) end
  if sec < 60 then return string.format("%ds", math.floor(sec + 0.5)) end
  return string.format("%dm%02ds", math.floor(sec / 60), math.floor(sec % 60))
end

local function set(buf, id, row, text, hl)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, 0, {
    id = id, virt_text = { { "  " .. text, hl } }, virt_text_pos = "eol",
    invalidate = true, undo_restore = false,
  })
end

local function row_of(buf, id)
  local pos = vim.api.nvim_buf_get_extmark_by_id(buf, ns, id, {})
  return pos[1]
end

-- Start timing the cell whose trigger is on `row` (0-indexed). `opts.quiet`:
-- only show the end result if it was slow (>= 1s) or failed (for listings,
-- which are usually instant). Returns a handle: handle.done(code, note).
function M.start(buf, row, opts)
  local nothing = { done = function() end }
  if require("bsh.config").status == false or not vim.api.nvim_buf_is_valid(buf) then return nothing end
  if row < 0 or row >= vim.api.nvim_buf_line_count(buf) then return nothing end
  opts = opts or {}
  vim.api.nvim_buf_clear_namespace(buf, ns, row, row + 1) -- a re-run replaces the old note
  local id = vim.api.nvim_buf_set_extmark(buf, ns, row, 0, { invalidate = true, undo_restore = false })
  local t0 = vim.uv.hrtime()
  local function elapsed() return (vim.uv.hrtime() - t0) / 1e9 end
  local timer = assert(vim.uv.new_timer())
  timer:start(1000, 1000, vim.schedule_wrap(function()
    if not vim.api.nvim_buf_is_valid(buf) then return timer:stop() end
    local r = row_of(buf, id)
    if r then set(buf, id, r, "running " .. fmt(elapsed()):gsub("%.%ds$", "s") .. "…", "Comment") end
  end))
  local h = {}
  function h.done(code, note)
    if timer:is_active() then timer:stop() end
    if not timer:is_closing() then timer:close() end
    if not vim.api.nvim_buf_is_valid(buf) then return end
    local r = row_of(buf, id)
    if not r then return end
    local sec = elapsed()
    local failed = note ~= nil or (code or 0) ~= 0
    if opts.quiet and not failed and sec < 1 then
      pcall(vim.api.nvim_buf_del_extmark, buf, ns, id)
      return
    end
    local tail = note or ((code or 0) == 0 and "ok" or ("exit " .. code))
    set(buf, id, r, fmt(sec) .. " · " .. tail, failed and "DiagnosticWarn" or "Comment")
  end
  return h
end

return M
