-- How options get into bsh.config: setup() (one option at a time), and a
-- module's own defaults (a rule's options, e.g. the agent's, are declared by the
-- rule, which loads with the engine -- after your setup() ran).
local config = require("bsh.config")

local api = {}
-- options set before the module that owns them registered its defaults (a rule's
-- options, e.g. the agent's, load with the engine, after your setup() ran)
local pending = {}

-- Set one option; a table merges into a table default (so adding one transport
-- keeps the rest). Returns false when no default with that name exists (yet).
function api.set(k, v)
  if config[k] == nil then
    pending[k] = v
    return false
  end
  if type(v) == "table" and type(config[k]) == "table" and not vim.islist(v) then
    config[k] = vim.tbl_extend("force", config[k], v)
  else
    config[k] = v
  end
  return true
end

-- A module's own option defaults (a rule's, say). Values already set by the
-- user win; ones set before this ran are applied on top now.
function api.defaults(D)
  for k, v in pairs(D) do
    if config[k] == nil then config[k] = v end
    if pending[k] ~= nil then
      local p = pending[k]
      pending[k] = nil
      api.set(k, p)
    end
  end
end

-- Options set that no module knows: warned about once the engine has loaded.
function api.unknown()
  local ks = vim.tbl_keys(pending)
  table.sort(ks)
  return ks
end

-- Tell the user about the options nothing knows (a typo, or a rule that's off).
function api.warn_unknown()
  for _, k in ipairs(api.unknown()) do
    vim.notify("bsh: unknown option '" .. tostring(k) .. "'", vim.log.levels.WARN)
    pending[k] = nil
  end
end

return api
