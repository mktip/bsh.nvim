-- `: <path>` directory listing / `-T` fold-tree / `: goto <query>` fuzzy jump,
-- plus the navigation primitives (open a file entry, find the enclosing fence,
-- reconstruct a fold-tree entry's path) and `https://` URL opening. Output is a
-- navigable `dir`/`tree` fence; clicks are resolved by the cell dispatcher.
local M = {}

local fence = require("bsh.fence")
local job = require("bsh.job")
local util = require("bsh.util")
local ns, inflight = fence.ns, fence.inflight
local stage_fence = fence.stage_fence
local build_argv, run_job, shell_transform, doc_cwd = job.build_argv, job.run_job, job.shell_transform, job.doc_cwd
local parse_list_args, qpath, fold_entry, join_path = util.parse_list_args, util.qpath, util.fold_entry, util.join_path

local run_goto -- forward decl (run_list dispatches to it; it lists the result)

-- Group a raw `ls -1p` listing into dirs-first-then-files (both stay in `ls`'s
-- own alpha order within their group); blank lines dropped. Shared by flat
-- `dir` mode and every fold-tree node listing (root + each expand).
local function group_entries(out)
  local dirs, files = {}, {}
  for _, l in ipairs(out) do
    if l ~= "" then
      if l:sub(-1) == "/" then dirs[#dirs + 1] = l else files[#files + 1] = l end
    end
  end
  local lines = {}
  vim.list_extend(lines, dirs)
  vim.list_extend(lines, files)
  return lines
end

-- Format one level's grouped `ls` output into fold-tree body lines at `depth`
-- (2 spaces per level): directories collapsed (`▸ name/`), files bare.
local function format_tree_level(entries, depth)
  local pad = string.rep("  ", depth)
  local lines = {}
  for _, e in ipairs(entries) do
    lines[#lines + 1] = pad .. (e:sub(-1) == "/" and ("▸ " .. e) or e)
  end
  return lines
end

-- `: <path>` (or `<user@host>: <path>`) : list a directory into a navigable
-- `dir` fence; with `-T`, a fold-tree `tree` fence whose directory nodes
-- expand/collapse in place (`M.toggle_tree_node`). Dotfiles hidden unless
-- `-H`. `ls -1p` is portable (BSD+GNU) and marks directories with a trailing /.
--
-- Special: `: goto <query>` fuzzy-resolves <query> to a path via the user's own
-- `here` helper (fd|fzf --filter, works locally or on the remote target) and
-- lists THAT -- so you can jump by a remembered fragment of a folder's name.
local function run_list(buf, trow, indent, target, rest)
  local path, flags = parse_list_args(rest)
  local query = path:match("^goto%s+(.+)$")
  if query then return run_goto(buf, trow, indent, target, query, flags) end
  local remote = target ~= ""
  local cwd = remote and nil or doc_cwd(buf)

  local ls = flags.hidden and "ls -1Ap -- " or "ls -1p -- "

  if flags.tree then
    local mark = stage_fence(buf, trow, indent, "tree", "...listing...")
    run_job(buf, indent, mark, build_argv(target, ls .. qpath(path)), cwd,
      function(out, err, code)
        if code ~= 0 then return shell_transform(out, err, code) end
        local lines = { "../" }
        vim.list_extend(lines, format_tree_level(group_entries(out), 0))
        return lines
      end)
    return
  end

  local mark = stage_fence(buf, trow, indent, "dir",
    remote and ("...listing " .. target .. "...") or "...listing...")
  run_job(buf, indent, mark, build_argv(target, ls .. qpath(path)), cwd,
    function(out, err, code)
      if code ~= 0 then return shell_transform(out, err, code) end
      local lines = { "../" }
      vim.list_extend(lines, group_entries(out))
      return lines
    end)
end

-- `: goto <query>` : resolve <query> with `here` (prints the best fuzzy path),
-- then rewrite the trigger to `: <resolved-path>` and list it in place -- the
-- same oil-style rewrite as drilling into a folder, just with a fuzzy entry
-- point. Works on the remote target too (its own `here`/$HOME).
function run_goto(buf, trow, indent, target, query, flags)
  local mark = stage_fence(buf, trow, indent, flags.tree and "tree" or "dir", "...resolving...")
  local out = {}
  local jb = vim.fn.jobstart(build_argv(target, "here " .. vim.fn.shellescape(query)), {
    cwd = target == "" and doc_cwd(buf) or nil,
    stdout_buffered = true,
    on_stdout = function(_, d) out = d or {} end,
    on_exit = function()
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(buf) then return end
        local pos = vim.api.nvim_buf_get_extmark_by_id(buf, ns, mark, {})
        if not pos[1] then return end
        local path
        for _, l in ipairs(out) do if l ~= "" then
            path = l; break
          end end
        if not path then -- no match: leave a note where the listing would be
          vim.api.nvim_buf_set_lines(buf, pos[1], pos[1] + 1, false,
            { indent .. "(goto: no match for '" .. query .. "')" })
          pcall(vim.api.nvim_buf_del_extmark, buf, ns, mark)
          if inflight[buf] then inflight[buf][mark] = nil end
          return
        end
        local suffix = (flags.tree and " -T" or "") .. (flags.hidden and " -H" or "")
        -- the body mark sits two rows below the trigger (trigger / ```open / body)
        local trig_row = pos[1] - 2
        vim.api.nvim_buf_set_lines(buf, trig_row, trig_row + 1, false,
          { indent .. (target ~= "" and (target .. ": ") or ": ") .. path .. suffix })
        run_list(buf, trig_row, indent, target, path .. suffix) -- re-stages the fence
      end)
    end,
  })
  if jb > 0 then
    inflight[buf][mark] = jb; pcall(vim.fn.chanclose, jb, "stdin")
  end
end

-- Open a file entry: local via :edit; remote via netrw scp:// (best effort,
-- needs netrw enabled). `~/x` -> home-relative URL, `/x` -> // absolute URL.
function M.open_entry(target, path)
  if target == "" then
    vim.cmd("edit " .. vim.fn.fnameescape(vim.fn.expand(path)))
    return
  end
  -- netrw shells out to `scp` for scp:// reads; without this it echoes the
  -- command and leaves a hit-ENTER prompt, so opening a remote file took two
  -- <CR>s. Silent transfers skip that prompt -> one <CR>, like local files.
  vim.g.netrw_silent = 1
  local rel = path:match("^~/(.*)$")
  local url = "scp://" .. target .. "/" .. (rel or path)
  vim.cmd("edit " .. vim.fn.fnameescape(url))
end

-- If `row` sits on an entry line inside a navigable fence, return its opening
-- fence row (0-indexed) and tag ("dir" | "tree"); otherwise nil.
function M.fence_open(buf, row)
  local cur = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
  if cur:match("^%s*```") then return nil end -- on a fence line, not an entry
  for r = row - 1, 0, -1 do
    local s = vim.api.nvim_buf_get_lines(buf, r, r + 1, false)[1] or ""
    local tag = s:match("^%s*```(%S+)%s*$")
    if tag then
      if tag == "dir" or tag == "tree" then return r, tag end
      return nil                                  -- some other fence (e.g. out) -> not navigable
    end
    if s:match("^%s*```%s*$") then return nil end -- closer above -> outside
  end
  return nil
end

-- Reconstruct the absolute path of the fold-tree entry at `row` by walking up
-- to collect one ancestor directory name per shallower depth, then joining
-- onto the listing's base path. `lo` is the fence's first body row (the `../`
-- line). Returns nil for a blank line (not an entry).
function M.fold_path(buf, lo, row, base)
  local function nm(r) return vim.api.nvim_buf_get_lines(buf, r, r + 1, false)[1] or "" end
  local depth, name = fold_entry(nm(row))
  if not depth then return nil end
  local parts, need = { [depth] = name }, depth - 1
  for r = row - 1, lo, -1 do
    local d, n = fold_entry(nm(r))
    if d == need then
      parts[need] = n; need = need - 1; if need < 0 then break end
    end
  end
  local rel = {}
  for d = 0, depth do rel[#rel + 1] = (parts[d] or ""):gsub("/$", "") end
  return join_path(base, table.concat(rel, "/"))
end

-- Toggle a fold-tree directory node in place: collapsed (`▸`) expands by
-- listing that node's absolute path (one level, same grouping as `dir` mode)
-- and splicing the result directly below it at one deeper indent, then flips
-- the marker to `▾`; expanded (`▾`) collapses by deleting exactly those
-- spliced lines (everything below it deeper than its own depth) and flips the
-- marker back. Siblings are untouched either way -- the whole point over the
-- old trigger-rewrite `dir` navigation, which replaces the entire listing.
-- `open` = the fence's opening fence row (0-indexed, from fence_open); `row` =
-- the clicked line; `base` = the fence's root path; `hidden` = the `-H` flag
-- from the trigger, threaded into every expansion so it applies uniformly.
function M.toggle_tree_node(buf, open, row, target, base, hidden)
  local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
  local depth, name, is_dir, expanded = fold_entry(line)
  if not depth or not is_dir then return false end
  local pad = string.rep("  ", depth)

  if expanded then
    local total = vim.api.nvim_buf_line_count(buf)
    local stop = row + 1
    while stop < total do
      local d = fold_entry(vim.api.nvim_buf_get_lines(buf, stop, stop + 1, false)[1] or "")
      if not d or d <= depth then break end
      stop = stop + 1
    end
    vim.api.nvim_buf_set_lines(buf, row, stop, false, { pad .. "▸ " .. name })
    return true
  end

  local full = M.fold_path(buf, open + 1, row, base)
  if not full then return false end
  local ls = hidden and "ls -1Ap -- " or "ls -1p -- "
  local cwd = target == "" and doc_cwd(buf) or nil
  vim.api.nvim_buf_set_lines(buf, row, row + 1, false, { pad .. "▾ " .. name, pad .. "  ...listing..." })
  local mark = vim.api.nvim_buf_set_extmark(buf, ns, row, 0, { right_gravity = false })
  local out = {}
  local jb = vim.fn.jobstart(build_argv(target, ls .. qpath(full)), {
    cwd = cwd,
    stdout_buffered = true,
    on_stdout = function(_, d) out = d or {} end,
    on_exit = function()
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(buf) then return end
        local pos = vim.api.nvim_buf_get_extmark_by_id(buf, ns, mark, {})
        if not pos[1] then return end
        local newlines = format_tree_level(group_entries(out), depth + 1)
        if #newlines == 0 then newlines = { string.rep("  ", depth + 1) .. "(empty)" } end
        vim.api.nvim_buf_set_lines(buf, pos[1] + 1, pos[1] + 2, false, newlines)
        pcall(vim.api.nvim_buf_del_extmark, buf, ns, mark)
      end)
    end,
  })
  if jb > 0 then pcall(vim.fn.chanclose, jb, "stdin") end
  return true
end

-- Open a URL in the browser: prefer $BROWSER (the user sets it per-OS), else
-- fall back to vim.ui.open (xdg-open/open/...). Detached so it outlives nvim.
function M.open_url(url)
  local browser = vim.env.BROWSER
  if browser and browser ~= "" then
    vim.fn.jobstart({ browser, url }, { detach = true })
  elseif vim.ui.open then
    vim.ui.open(url)
  else
    vim.fn.jobstart({ "xdg-open", url }, { detach = true })
  end
end

M.run_list = run_list
return M
