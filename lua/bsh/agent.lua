-- `> instruction` agent cells: call the `llm` CLI, optionally folding in N
-- preceding cells as context (`>` none, `>>` one, `>>>` two, …). Output goes in
-- an owned `agent` fence; a model-emitted ``` is neutralised so it can't close
-- our fence early.
local M = {}

local fence = require("bsh.fence")
local job = require("bsh.job")
local config = require("bsh.config")
local stage_fence = fence.stage_fence
local run_job, shell_transform, doc_cwd = job.run_job, job.shell_transform, job.doc_cwd

-- Swap every literal ``` run for a backtick LOOK-ALIKE (U+02CB MODIFIER LETTER
-- GRAVE ACCENT, ˋˋˋ) so the model's code blocks still read as code blocks but can
-- never terminate our real `agent` fence. Single/double inline backticks are left
-- alone. Used both as the final transform and the live-preview line_xform.
local function agent_sanitize(l) return (l:gsub("```", "ˋˋˋ")) end
local function agent_transform(out_data, err_data, code)
  local lines = shell_transform(out_data, err_data, code)
  for i, l in ipairs(lines) do lines[i] = agent_sanitize(l) end
  return lines
end

-- Identify the cell whose bottom is at/above row `from` (skipping blanks) and
-- return its context text plus the row of its top line (so a caller can keep
-- walking up). Recognises: a fenced block (its trigger + body), an agent region
-- (its `>` line + body), a bare URL, or a bare trigger with no result yet.
-- Returns nil on prose / nothing (which stops the walk).
local function cell_above(buf, from)
  local function gl(r) return vim.api.nvim_buf_get_lines(buf, r, r + 1, false)[1] or "" end
  local function looks_trigger(s)
    return s:match("^%S-" .. vim.pesc(config.marker) .. "%s") or s:match("^%S-:%s")
        or s:match("^https?://") or s:match("^>+%s")
  end
  local r = from
  while r >= 0 and gl(r):match("^%s*$") do r = r - 1 end
  if r < 0 then return nil end
  local f = gl(r)

  if f:match("^%s*```%s*$") then -- closing fence of an out/dir/tree block
    local openr
    for rr = r - 1, 0, -1 do
      if gl(rr):match("^%s*```%S") then
        openr = rr; break
      end
      if gl(rr):match("^%s*```%s*$") then break end
    end
    if not openr then return nil end
    local parts, top = {}, openr
    local trig = gl(openr - 1):gsub("^%s+", "")
    if looks_trigger(trig) then
      parts[#parts + 1] = trig; top = openr - 1
    end
    vim.list_extend(parts, vim.api.nvim_buf_get_lines(buf, openr + 1, r, false))
    return table.concat(parts, "\n"), top
  end

  if looks_trigger(f:gsub("^%s+", "")) then return (f:gsub("^%s+", "")), r end
  return nil -- prose -> stop
end

-- Gather up to `n` preceding cells as context, in document order (oldest first).
local function gather_context(buf, row, n)
  if n <= 0 then return nil end
  local blocks, from = {}, row - 1
  while #blocks < n do
    local text, top = cell_above(buf, from)
    if not text then break end
    blocks[#blocks + 1] = text
    from = top - 1
  end
  if #blocks == 0 then return nil end
  local ordered = {}
  for i = #blocks, 1, -1 do ordered[#ordered + 1] = blocks[i] end
  return table.concat(ordered, "\n\n")
end

-- `> instruction` : agentic llm call. The number of leading `>` beyond the first
-- picks how many preceding cells to include: `>` = none, `>>` = 1, `>>>` = 2, …
function M.run_agent(buf, trow, indent, instruction, ncontext)
  local context = gather_context(buf, trow, ncontext)
  local prompt = instruction
  if context and context ~= "" then
    prompt = prompt .. "\n\n--- preceding cells (context) ---\n" .. context
  end
  local mark = stage_fence(buf, trow, indent, "agent", "...thinking...")
  run_job(buf, indent, mark,
    { "llm", "-t", config.agent_template, "--chain-limit", "15", prompt },
    doc_cwd(buf), agent_transform, agent_sanitize) -- sanitize the live preview too
end

return M
