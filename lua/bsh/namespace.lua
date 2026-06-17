-- The namespace: the directory tree under $BSH_HOME *is* a command palette,
-- 1:1, no registry. A dotted name (`llm.tools.weather`) maps to a path (dots ->
-- slashes); <CR> runs it (file by shebang / dir's `.enter` / else lists it) and
-- `foo.bar!` edits or scaffolds its source. The run goes through `$`'s one-shot
-- shell, so a leaf is a true shell continuation (redirection/pipes/globs/$()).
local M = {}

local config = require("bsh.config")
local run_shell = require("bsh.job").run_shell
local run_list = require("bsh.listing").run_list

-- The namespace root ($BSH_HOME, default ~/pockt/bsh). Returns "" when it
-- doesn't exist, so namespace cells simply don't fire if it isn't set up (prose
-- stays prose). The directory tree under it IS the namespace, 1:1, no registry.
function M.ns_home()
  local h = vim.env.BSH_HOME
  if not h or h == "" then h = "~/pockt/bsh" end
  h = vim.fn.expand(h)
  return vim.fn.isdirectory(h) == 1 and h or ""
end

-- Does `dotted` resolve to something under $BSH_HOME (a dir, a leaf file, or a
-- single-extension sibling)? A cheap path-only check -- no execution -- used to
-- decide whether a command's output fence should behave as a drillable menu.
function M.resolves(dotted)
  local home = M.ns_home()
  if home == "" then return false end
  local clean = (dotted:gsub("%.+$", ""))
  if clean == "" then return false end
  local base = home .. "/" .. (clean:gsub("%.", "/"))
  if vim.fn.isdirectory(base) == 1 or vim.fn.filereadable(base) == 1 then return true end
  return #vim.fn.glob(base .. ".*", false, true) > 0
end

-- Run a resolved namespace leaf as a SHELL command (not a bare argv), so the
-- cell is a continuation of the shell: `args` is appended raw and the whole line
-- goes through `$`'s one-shot shell, giving redirection, pipes, globs, `$(...)`
-- sub-shells -- everything the outer shell does. The path is quoted; args are not
-- (they ARE shell syntax). Runs in the document's dir, like `$`.
local function run_ns_exec(buf, trow, indent, path, args, to_buf)
  local cmd = vim.fn.shellescape(path)
  if args and args ~= "" then cmd = cmd .. " " .. args end
  run_shell(buf, trow, indent, "", cmd, to_buf)
end

-- A `namespace` cell resolves a dotted name to a path under $BSH_HOME (dots ->
-- slashes): `llm.tools.weather`. Enter dispatches on what's there:
--   * a file is executed by its shebang into an `out` fence (so a dual-purpose
--     `weather.py` runs its `__main__`); the leaf may carry any extension
--     (`...weather` matches `weather` or `weather.<ext>`) since dispatch is
--     shebang- not extension-driven;
--   * a directory with an executable `.enter` runs that;
--   * a directory without one is LISTED -- and the trigger is canonicalised to a
--     TRAILING DOT (`demo` -> `demo.`) so its entries navigate as `demo.<child>`.
-- A trailing dot is also an explicit "peek inside" operator: `demo.greet.` lists
-- the dir even when `demo.greet` (no dot) would have run its `.enter`.
-- `args` (the rest of the line after the dotted name) is passed to an executable
-- leaf/`.enter` as shell args; for a plain directory it's meaningless, so
-- `<dir> <args>` falls through to prose.
-- Returns true if it resolved+handled, false (prose) otherwise.
function M.run_namespace(buf, trow, indent, dotted, args, to_buf)
  args = args or ""
  local home = M.ns_home()
  if home == "" then return false end
  local force_list = dotted:sub(-1) == "."          -- trailing dot = list, not .enter
  local clean = (dotted:gsub("%.+$", ""))           -- strip trailing dot(s)
  if clean == "" then return false end
  local base = home .. "/" .. (clean:gsub("%.", "/"))

  if vim.fn.isdirectory(base) == 1 then
    local enter = base .. "/.enter"
    if not force_list and vim.fn.executable(enter) == 1 then
      run_ns_exec(buf, trow, indent, enter, args, to_buf)
    elseif args ~= "" then
      return false -- `<dir> <args>` with nothing to run -> prose
    else
      -- canonicalise the trigger to `clean.` so the listing's entries resolve as
      -- `clean.<child>` (and re-running this cell is idempotent). List with -H so
      -- the `.enter` (and any other dotfiles in the namespace) are visible.
      vim.api.nvim_buf_set_lines(buf, trow, trow + 1, false, { indent .. clean .. "." })
      run_list(buf, trow, indent, "", base .. " -H") -- navigable listing, hidden shown
    end
    return true
  end

  -- a leaf file: try the exact name, then any single-extension sibling
  local cands = { base }
  for _, g in ipairs(vim.fn.glob(base .. ".*", false, true)) do cands[#cands + 1] = g end
  for _, p in ipairs(cands) do
    if vim.fn.filereadable(p) == 1 then
      if vim.fn.executable(p) == 1 then
        run_ns_exec(buf, trow, indent, p, args, to_buf) -- run by shebang, through the shell
      else
        vim.notify("bsh: " .. p .. " is not executable (chmod +x it)", vim.log.levels.WARN)
      end
      return true
    end
  end
  return false -- nothing under $BSH_HOME -> treat as prose
end

-- The candidate source file for a resolved namespace leaf (exact name first, then
-- a single-extension sibling like `weather.py`); nil if none exists yet.
local function ns_leaf_path(base)
  if vim.fn.filereadable(base) == 1 then return base end
  for _, g in ipairs(vim.fn.glob(base .. ".*", false, true)) do
    if vim.fn.filereadable(g) == 1 then return g end
  end
  return nil
end

-- Starter templates for a freshly scaffolded leaf. `@N@` = the dotted name, `@F@`
-- = the last segment as a valid identifier. Shell is the low-friction default;
-- python is the dual-purpose command/`llm`-tool keystone.
local SCAFFOLD = {
  sh = {
    ext = ".sh",
    body = table.concat({
      "#!/usr/bin/env bash",
      "# bsh command: @N@   (run with: @N@ [args]; args are in \"$@\")",
      "",
      'echo "hello from @N@ $*"',
      "",
    }, "\n"),
  },
  python = {
    ext = ".py",
    body = table.concat({
      "#!/usr/bin/env python3",
      '"""@N@ — a bsh command / llm tool."""',
      "import sys",
      "",
      "",
      "def @F@(text: str = \"\") -> str:",
      '    "TODO: describe what @F@ does."',
      "    return text",
      "",
      "",
      "try:",
      "    import llm",
      "",
      "    @llm.hookimpl",
      "    def register_tools(register):",
      "        register(@F@)",
      "except ImportError:",
      "    pass",
      "",
      "",
      'if __name__ == "__main__":',
      "    print(@F@(\" \".join(sys.argv[1:])))",
      "",
    }, "\n"),
  },
}

-- Write an executable scaffold for `dotted` at `path` and return it. Creates
-- parent dirs; fills the template; sets the exec bit so it's runnable at once.
local function scaffold_leaf(dotted, path)
  local fname = (dotted:gsub(".*%.", "")):gsub("[^%w_]", "_")
  local spec = SCAFFOLD[config.scaffold_lang] or SCAFFOLD.sh
  local body = (spec.body:gsub("@N@", dotted):gsub("@F@", fname))
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile(vim.split(body, "\n"), path)
  vim.fn.setfperm(path, "rwxr-xr-x")
  return path
end

-- `foo.bar!` : edit the leaf's SOURCE -- the authoring half of the namespace.
-- Existing leaf/`.enter` opens straight in a split; a missing one is scaffolded
-- (after a confirm, so a stray `word!` line can't silently create a file) with a
-- shebang skeleton and opened. Returns true if handled (home set), false (prose).
function M.edit_namespace(dotted)
  local home = M.ns_home()
  if home == "" then return false end
  local base = home .. "/" .. (dotted:gsub("%.", "/"))

  -- existing: a leaf file, or a directory's `.enter` (its behavior definition)
  local path = ns_leaf_path(base)
  if not path and vim.fn.isdirectory(base) == 1 then
    local enter = base .. "/.enter"
    path = vim.fn.filereadable(enter) == 1 and enter or nil
    if not path then -- offer to define this folder's `.enter`
      if not config.confirm("bsh: define " .. dotted .. "/.enter ?") then return true end
      path = scaffold_leaf(dotted, enter)
    end
  elseif not path then -- nothing there: scaffold a new leaf (with a typo-guard)
    if not config.confirm("bsh: create command '" .. dotted .. "' ?") then return true end
    path = scaffold_leaf(dotted, base .. (SCAFFOLD[config.scaffold_lang] or SCAFFOLD.sh).ext)
  end

  vim.cmd("split " .. vim.fn.fnameescape(path))
  return true
end

return M
