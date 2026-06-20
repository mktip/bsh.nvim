-- `: <path>` directory listing / `-T` tree / `: goto <query>` fuzzy jump, plus
-- the navigation primitives (open a file entry, find the enclosing fence,
-- reconstruct a tree entry's path) and `https://` URL opening. Output is a
-- navigable `dir`/`tree` fence; clicks are resolved by the cell dispatcher.
local M = {}

local fence = require("bsh.fence")
local job = require("bsh.job")
local util = require("bsh.util")
local ns, inflight = fence.ns, fence.inflight
local stage_fence = fence.stage_fence
local build_argv, run_job, shell_transform, doc_cwd = job.build_argv, job.run_job, job.shell_transform, job.doc_cwd
local parse_list_args, qpath, tree_entry, join_path = util.parse_list_args, util.qpath, util.tree_entry, util.join_path

local run_goto -- forward decl (run_list dispatches to it; it lists the result)

-- `: <path>` (or `<user@host>: <path>`) : list a directory into a navigable
-- `dir` fence; with `-T`, a navigable `tree` fence (paths reconstructed from the
-- tree's indentation on <CR>). Dotfiles hidden unless `-H`. `ls -1p` / `tree -F`
-- are portable (BSD+GNU) and mark directories with a trailing /.
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

  if flags.tree then
    local mark = stage_fence(buf, trow, indent, "tree", "...listing...")
    -- tree -F marks dirs with /, needed to resolve clicks; -a shows hidden.
    local cmd = "tree -F " .. (flags.hidden and "-a " or "") .. "-- " .. qpath(path)
    run_job(buf, indent, mark, build_argv(target, cmd), cwd, shell_transform)
    return
  end

  local ls = flags.hidden and "ls -1Ap -- " or "ls -1p -- "
  local mark = stage_fence(buf, trow, indent, "dir",
    remote and ("...listing " .. target .. "...") or "...listing...")
  run_job(buf, indent, mark, build_argv(target, ls .. qpath(path)), cwd,
    function(out, err, code)
      if code ~= 0 then return shell_transform(out, err, code) end
      -- group dirs first (trailing /), then files; prepend ../ for walking up
      local dirs, files = {}, {}
      for _, l in ipairs(out) do
        if l ~= "" then
          if l:sub(-1) == "/" then dirs[#dirs + 1] = l else files[#files + 1] = l end
        end
      end
      local lines = { "../" }
      vim.list_extend(lines, dirs)
      vim.list_extend(lines, files)
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

-- Reconstruct the path of the tree entry at `row` by walking up to collect one
-- ancestor name per shallower depth, then joining onto the listing's base path.
-- `lo` is the first body row of the fence. Returns full_path, is_dir (or nil).
function M.tree_path(buf, lo, row, base)
  local function nm(r) return vim.api.nvim_buf_get_lines(buf, r, r + 1, false)[1] or "" end
  local depth, name = tree_entry(nm(row))
  if not depth then return nil end
  local parts, need = { [depth] = name }, depth - 1
  for r = row - 1, lo, -1 do
    local d, n = tree_entry(nm(r))
    if d == need then
      parts[need] = n; need = need - 1; if need == 0 then break end
    end
  end
  -- strip tree -F type markers (/ * = @ |) to recover bare names
  local rel = {}
  for d = 1, depth do rel[d] = (parts[d] or ""):gsub("[/*=@|]$", "") end
  return join_path(base, table.concat(rel, "/")), name:sub(-1) == "/"
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
