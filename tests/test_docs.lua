-- Every option has an entry in :help bsh-config, so the docs can't fall behind
-- the code (an option added without one fails here).
local eq = MiniTest.expect.equality
local T = MiniTest.new_set()

-- not listed on purpose
local UNLISTED = {
  confirm = "a hook (the yes/no before `name!` scaffolds), replaced by tests",
  agent_thread = "the old name of agent_memory, mentioned under it",
}

T["every option is in doc/bsh.txt's configuration section"] = function()
  require("bsh.contrib.agent") -- declares the agent's options
  local doc = table.concat(vim.fn.readfile("doc/bsh.txt"), "\n")
  local section = doc:match("%*bsh%-config%*(.-)\n=====") or doc:match("%*bsh%-config%*(.*)$")
  local missing = {}
  for k in pairs(require("bsh.config")) do
    if not UNLISTED[k] and not section:find("\n" .. k .. "%s") then missing[#missing + 1] = k end
  end
  table.sort(missing)
  eq(missing, {})
end

return T
