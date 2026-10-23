local H = require("tests.helpers")
local eq = MiniTest.expect.equality

local child = H.child()
local T = H.set(child)

-- A fake `pi` on $PATH that ignores its args and prints canned JSONL events.
local function fake_pi()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  vim.fn.writefile({
    "#!/bin/sh",
    [[echo '{"type":"session"}']],
    [[echo '{"type":"message_update","assistantMessageEvent":{"type":"thinking_delta","delta":"hmm"}}']],
    [[echo '{"type":"tool_execution_start","toolName":"ls","args":{"path":"/tmp"}}']],
    [[echo '{"type":"message_update","assistantMessageEvent":{"type":"text_start"}}']],
    [[echo '{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"Hello "}}']],
    [[echo '{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"```world"}}']],
  }, dir .. "/pi")
  vim.fn.setfperm(dir .. "/pi", "rwxr-xr-x")
  return dir
end

T["decode_pi: text deltas + tool lines, thinking dropped, partial tail skipped"] = function()
  H.bootstrap(child, { lines = {} })
  local out = child.lua_get([[require('bsh.agent').decode_pi(table.concat({
    '{"type":"message_update","assistantMessageEvent":{"type":"thinking_delta","delta":"x"}}',
    '{"type":"tool_execution_start","toolName":"bash","args":{"command":"ls   -l"}}',
    '{"type":"tool_execution_end","toolName":"bash","isError":true}',
    '{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"done"}}',
    '{"type":"message_upd',
  }, "\n"))]])
  eq(out, "⚙ bash ls -l ✗\ndone")
end

T["decode_pi: non-JSON output passes through raw"] = function()
  H.bootstrap(child, { lines = {} })
  eq(child.lua_get([[require('bsh.agent').decode_pi("boom: no auth\n")]]), "boom: no auth\n")
end

T["`>` cell runs pi headless and renders its events (``` neutralised)"] = function()
  local dir = fake_pi()
  H.bootstrap(child, { lines = { "> say hi" } })
  child.lua("vim.env.PATH = ... .. ':' .. vim.env.PATH; require('bsh.config').agent = 'pi'", { dir })
  H.run(child, 1)
  eq(H.lines(child), { "> say hi", "```agent", "⚙ ls /tmp", "Hello ˋˋˋworld", "```" })
end

return T
