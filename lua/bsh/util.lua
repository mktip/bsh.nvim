-- Pure helpers: string / path / argument parsing. No buffer, extmark, or plugin
-- state -- everything here is a function of its inputs, so it's trivially unit
-- testable and safe to require from anywhere.
local M = {}

-- `: path [-T] [-H]` : peel any trailing recognised flags off the trigger
-- remainder, leaving the path. -T = tree view, -H = include hidden (dotfiles).
-- Empty path means the document/login dir.
function M.parse_list_args(rest)
  local flags = { tree = false, hidden = false }
  local path = rest
  while true do
    local f = path:match("%s(%-%a)%s*$")
    if f == "-T" then
      flags.tree = true
    elseif f == "-H" then
      flags.hidden = true
    else
      break -- no flag, or an unknown one we leave in the path
    end
    path = path:gsub("%s%-%a%s*$", "", 1)
  end
  path = (path:gsub("^%s+", "")):gsub("%s+$", "")
  if path == "" then
    path = "."
  end
  return path, flags
end

-- Quote a path for the shell while keeping a leading ~ / ~user prefix expandable.
-- Tilde expansion needs the slash right after ~ to be UNQUOTED (it ends the
-- tilde-prefix), so keep `~prefix/` verbatim and shellescape only the rest.
function M.qpath(path)
  local pre, rest = path:match("^(~[^/]*/)(.*)$")
  if pre then
    return pre .. (rest == "" and "" or vim.fn.shellescape(rest))
  end
  if path:match("^~[^/]*$") then
    return path -- bare ~ or ~user
  end
  return vim.fn.shellescape(path)
end

-- Join a listing's base path with a clicked entry; `..` walks up one segment
-- (pure string op, so it works for remote paths too).
function M.join_path(base, name)
  if name == ".." then
    return vim.fn.fnamemodify((base:gsub("/+$", "")), ":h")
  end
  base = (base:gsub("/+$", ""))
  if base == "" then
    base = "."
  end
  return base .. "/" .. name
end

-- Parse one fold-tree body line into (depth, name, is_dir, expanded). Depth =
-- leading-space count / 2 (2 spaces per nesting level). A directory carries a
-- fold marker, `+` collapsed / `-` expanded; a file is bare `<indent>name`
-- (no marker). Blank/whitespace-only lines -> nil (not an entry).
function M.fold_entry(line)
  local indent, rest = line:match("^( *)(.*)$")
  if rest == "" then return nil end
  local depth = math.floor(#indent / 2)
  local name = rest:match("^%+%s(.+)$")
  if name then return depth, name, true, false end
  name = rest:match("^%-%s(.+)$")
  if name then return depth, name, true, true end
  return depth, rest, false, nil
end

-- A fence info-string's run marker -> (lang, target, session). Drives which
-- engine a ` ```lang % ` / ` ```%% ` input fence uses; nil lang = inert. `marker`
-- is the configured shell symbol (config.marker) -- passed in so this stays a
-- pure function; the patterns are built from its pattern-escaped form. Session =
-- the optional SECOND marker is present.
local LANG_ALIAS = { sh = "sh", bash = "sh", shell = "sh", py = "python", python = "python" }
function M.parse_runmarker(info, marker)
  local m = vim.pesc(marker)
  local pat = "^(%S-)" .. m .. "(" .. m .. "?)$"
  local word, rest = info:match("^(%a[%w_]*)%s+(.+)$")
  if word then -- language-prefixed form
    local lang = LANG_ALIAS[word]
    if not lang then
      return nil
    end
    local tgt, dbl = rest:match(pat)
    if tgt then
      return lang, tgt, dbl ~= ""
    end
    return nil
  end
  local tgt, dbl = info:match(pat) -- bare bash form
  if tgt then
    return "sh", tgt, dbl ~= ""
  end
  return nil
end

return M
