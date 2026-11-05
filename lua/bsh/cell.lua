-- The cell grammar: what a line IS, from its text alone. An ordered list of
-- rules, first match wins (like Plan 9's plumbing rules). Every place that needs
-- to know "is this a cell, and which kind" asks `parse`: the <CR> dispatcher,
-- ]c / [c, <M-CR>, visual <CR>, :BshReplay.
--
-- A parsed cell is a table: { kind, indent, prefix, ... }, where `prefix` is the
-- text before the body (`user@host%% `, `>> `), the part <M-CR> repeats.
-- Kinds and their fields:
--   shell   target, session (bool), body          `% cmd`, `user@host%% cmd`
--   url     url                                   `https://...`
--   agent   template|nil, stateful, bang, body    `> q`, `[model]>>! q`
--   list    target, body                          `: path`, `user@host: path`
--   nsedit  name                                  `foo.bar!`
--   ns      name, args|nil                        `foo.bar args` -- TENTATIVE:
--           any `word ...` line parses as one; it's a cell only if the name
--           resolves under $BSH_HOME (bsh.namespace decides).
-- Multiline input fences (```python %%) and positions inside result fences are
-- not line cells; the dispatcher handles those first (see bsh.init).
local M = {}

local config = require("bsh.config")

local function shell(line)
  local m = vim.pesc(config.marker)
  local prefix, indent, target, marks, body =
      line:match("^((%s*)(%S-)(" .. m .. m .. "?)%s+)(.-)%s*$")
  if not (body and body ~= "") then return nil end
  return { prefix = prefix, indent = indent, target = target,
    session = marks == config.marker .. config.marker, body = body }
end

local function url(line)
  local indent, u = line:match("^(%s*)(https?://%S+)%s*$")
  if u then return { indent = indent, prefix = indent, url = u } end
end

local function agent(line)
  local prefix, indent, tpl, arrows, bang, body =
      line:match("^((%s*)%[([%w_%-]+)%](>+)(!?)%s+)(%S.-)%s*$")
  if not body then
    prefix, indent, arrows, bang, body = line:match("^((%s*)(>+)(!?)%s+)(%S.-)%s*$")
  end
  if not body then return nil end
  return { prefix = prefix, indent = indent, template = tpl,
    stateful = #arrows >= 2, bang = bang == "!", body = body }
end

-- The colon must be the first non-blank char (local) or follow a route: one with
-- an `@` in it, or a route alias. So prose like "TODO: fix" isn't a listing.
local function list(line)
  local prefix, indent, target, body = line:match("^((%s*)(%S-):%s+)(%S.-)%s*$")
  if body and (target == "" or target:find("@")
        or (config.routes or {})[(target:match("^[^/]+"))]) then
    return { prefix = prefix, indent = indent, target = target, body = body }
  end
end

local function nsedit(line)
  local indent, name = line:match("^(%s*)([%w_][%w_%.%-]*)!%s*$")
  if name then return { indent = indent, prefix = indent, name = name } end
end

local function ns(line)
  local indent, name, args = line:match("^(%s*)([%w_][%w_%.%-]*)%s+(%S.-)%s*$")
  if not name then indent, name = line:match("^(%s*)([%w_][%w_%.%-]*)%s*$") end
  if name then return { indent = indent, prefix = indent, name = name, args = args } end
end

M.rules = {
  { kind = "shell", parse = shell },
  { kind = "url", parse = url },
  { kind = "agent", parse = agent },
  { kind = "list", parse = list },
  { kind = "nsedit", parse = nsedit },
  { kind = "ns", parse = ns },
}

-- Parse `line` into a cell, or nil if no rule matches.
function M.parse(line)
  for _, r in ipairs(M.rules) do
    local c = r.parse(line)
    if c then
      c.kind = r.kind
      return c
    end
  end
end

-- A user rule from config.rules matching `line`: returns (rule, captures) or nil.
-- A rule is { match = <lua pattern>, run = function(ctx, ...captures) }.
function M.user_rule(line)
  for _, r in ipairs(config.rules or {}) do
    local caps = { line:match(r.match) }
    if caps[1] ~= nil then return r, caps end
  end
end

return M
