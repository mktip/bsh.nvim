-- The cell grammar: what a line IS, from its text alone. An ordered list of
-- rules, first match wins (like Plan 9's plumbing rules). Every place that needs
-- to know "is this a cell, and which kind" asks `parse`: the <CR> dispatcher,
-- ]c / [c, <M-CR>, visual <CR>, :BshReplay.
--
-- A parsed cell is a table: { kind, indent, prefix, ... }, where `prefix` is the
-- text before the body (`user@host%% `), the part <M-CR> repeats.
-- Kinds and their fields:
--   shell   target, session (bool), body          `% cmd`, `user@host%% cmd`
--   url     url                                   `https://...`
--   list    target, body                          `: path`, `user@host: path`
--   nsedit  name                                  `foo.bar!`
--   ns      name, args|nil                        `foo.bar args` -- TENTATIVE:
--           any `word ...` line parses as one; it's a cell only if the name
--           resolves under $BSH_HOME (bsh.namespace decides).
-- Multiline input fences (```python %%) and positions inside result fences are
-- not line cells; the dispatcher handles those first (see bsh.init).
--
-- Cell kinds that aren't built into the grammar -- yours (config.rules) and the
-- bundled ones written the same way (bsh.contrib.*, e.g. the `>` agent) -- are
-- RULES: see M.rule_for below.
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

-- Rules: cell kinds defined outside the grammar, tried before it (first match
-- wins). Yours come from config.rules; bundled kinds (bsh.contrib.*) register
-- here and come after yours, so a rule of your own can take over their syntax.
-- A rule:
--   match   a Lua pattern (its captures go to run) or function(line) -> value(s)|nil
--   run     function(ctx, ...captures) -> shell cmd string | false (pass) | nil (handled)
--   prompt  function(line) -> prefix|nil   what <M-CR> repeats for a new cell
--   tag     the fence tag its output owns (see bsh.fence.own_tag)
--   fold    { test = function(line) -> bool, label = "..." }: runs of matching
--           lines inside its fence fold on their own (level 2)
--   attach  function(buf): keys/commands, run for every bsh buffer
local builtin = {}

function M.register(rule)
  for i, r in ipairs(builtin) do
    if r.name and r.name == rule.name then builtin[i] = rule; return end
  end
  builtin[#builtin + 1] = rule
  if rule.tag then require("bsh.fence").own_tag(rule.tag, rule.fold) end
end

function M.unregister(name)
  for i, r in ipairs(builtin) do
    if r.name == name then table.remove(builtin, i); return end
  end
end

-- Every rule, in the order they're tried: config.rules, then the bundled ones.
function M.rules_list()
  local all = {}
  for _, r in ipairs(require("bsh.config").rules or {}) do
    if r.tag then require("bsh.fence").own_tag(r.tag, r.fold) end
    all[#all + 1] = r
  end
  for _, r in ipairs(builtin) do all[#all + 1] = r end
  return all
end

local function try(r, line)
  if type(r.match) == "function" then
    local caps = { r.match(line) }
    if caps[1] ~= nil then return caps end
  elseif type(r.match) == "string" then
    local caps = { line:match(r.match) }
    if caps[1] ~= nil then return caps end
  end
end

-- The first rule matching `line`: returns (rule, captures) or nil.
function M.rule_for(line)
  for _, r in ipairs(M.rules_list()) do
    local caps = try(r, line)
    if caps then return r, caps end
  end
end
M.user_rule = M.rule_for -- (older name)

return M
