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

T["decode_pi: thinking + text deltas + tool lines, partial tail skipped"] = function()
  H.bootstrap(child, { lines = {} })
  local out = child.lua_get([[require('bsh.agent').decode_pi(table.concat({
    '{"type":"message_update","assistantMessageEvent":{"type":"thinking_start"}}',
    '{"type":"message_update","assistantMessageEvent":{"type":"thinking_delta","delta":"a\\nb"}}',
    '{"type":"message_update","assistantMessageEvent":{"type":"thinking_end"}}',
    '{"type":"tool_execution_start","toolCallId":"t1","toolName":"bash","args":{"command":"ls   -l"}}',
    '{"type":"tool_execution_end","toolCallId":"t1","toolName":"bash","result":{"content":[{"type":"text","text":"total 0"}]}}',
    '{"type":"tool_execution_start","toolCallId":"t2","toolName":"read","args":{"path":"x.lua"}}',
    '{"type":"tool_execution_end","toolCallId":"t2","toolName":"read","isError":true}',
    '{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"done"}}',
    '{"type":"message_upd',
  }, "\n"))]])
  -- text / tool call / text, flat: tool calls that can be re-run are cells (with the
  -- result pi saw); other tools stay `⚙` notes inside the text
  eq(out, table.concat({ "```agent", "∴ a", "∴ b", "```", "% ls   -l  # ⚙", "```out", "total 0", "```",
    "```agent", "⚙ read x.lua ✗", "done", "```" }, "\n"))
end

T["decode_pi: non-JSON output passes through raw"] = function()
  H.bootstrap(child, { lines = {} })
  eq(child.lua_get([[require('bsh.agent').decode_pi("boom: no auth\n")]]), "```agent\nboom: no auth\n```")
end

T["`>` cell runs pi headless and renders its events (``` neutralised)"] = function()
  local dir = fake_pi()
  H.bootstrap(child, { lines = { "> say hi" } })
  child.lua("vim.env.PATH = ... .. ':' .. vim.env.PATH; require('bsh.config').agent = 'pi'", { dir })
  H.run(child, 1)
  eq(H.lines(child), { "> say hi", "```agent", "∴ hmm", "```", "% ls '/tmp'  # ⚙", "```out", "(no result)", "```",
    "```agent", "Hello ˋˋˋworld", "```" })
end

-- A fake `pi` that echoes the prompt it was given (its last argv) back as the reply,
-- or, when $FAKE_PI_REPLY is set, replies with that text instead.
local function echo_pi()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  vim.fn.writefile({
    "#!/usr/bin/env python3",
    "import json, os, sys",
    "t = os.environ.get('FAKE_PI_REPLY') or sys.argv[-1]",
    "print(json.dumps({'type': 'message_update', 'assistantMessageEvent': {'type': 'text_delta', 'delta': t}}))",
  }, dir .. "/pi")
  vim.fn.setfperm(dir .. "/pi", "rwxr-xr-x")
  return dir
end

local function boot(lines)
  local dir = echo_pi()
  H.bootstrap(child, { lines = lines })
  child.lua("vim.env.PATH = ... .. ':' .. vim.env.PATH; require('bsh.config').agent = 'pi'", { dir })
end

T["`>` is stateless: only the instruction is sent"] = function()
  boot({ "% echo earlier", "> what is up" })
  H.run(child, 2)
  eq(H.lines(child)[4], "what is up")
end

T["`>>` sends the thread: earlier ask, reply and cells in between, up to a `>`"] = function()
  boot({ "forgotten prose", "> first q", "```agent", "first a", "```", "% echo mid", "```out", "mid", "```", ">> follow up" })
  H.run(child, 10)
  local out = table.concat(vim.list_slice(H.lines(child), 12), "\n")
  for _, want in ipairs({ "[you asked] first q", "[agent replied]", "first a", "%% echo mid", "mid", "follow up" }) do
    eq(out:find(want:gsub("%%%%", "%%"), 1, true) ~= nil, true, want)
  end
  eq(out:find("forgotten prose", 1, true), nil) -- before the thread's `>`
end

T["a heading ends the thread"] = function()
  boot({ "> old q", "# New section", "% echo hi", ">> next" })
  H.run(child, 4)
  local out = table.concat(vim.list_slice(H.lines(child), 6), "\n")
  eq(out:find("old q", 1, true), nil)
  eq(out:find("echo hi", 1, true) ~= nil, true)
end

T["visual <CR> ending on a `>` cell attaches the selected lines"] = function()
  boot({ "alpha line", "beta line", "> explain", "tail" })
  child.type_keys("ggVjj") -- select rows 1..3, ending on the `>` cell
  child.type_keys("<CR>")
  vim.loop.sleep(1500)
  local out = table.concat(H.lines(child), "\n")
  eq(out:find("--- attached selection", 1, true) ~= nil, true)
  eq(out:find("alpha line\nbeta line", 1, true) ~= nil, true)
end

T["proposed `sh %` blocks are lifted out of the agent fence into live cells"] = function()
  boot({ "> suggest" })
  child.lua("vim.env.FAKE_PI_REPLY = ...", { "Try this:\n```sh %\nls -la\n```\nthen look." })
  H.run(child, 1)
  eq(H.lines(child), { "> suggest", "```agent", "Try this:", "then look.", "```", "", "% ls -la  # ⚙" })
end

T["a multi-line proposal becomes a tagged fence cell"] = function()
  boot({ "> suggest" })
  child.lua("vim.env.FAKE_PI_REPLY = ...", { "Run:\n```sh %\nfor f in a b; do\n  echo $f\ndone\n```" })
  H.run(child, 1)
  eq(H.lines(child), { "> suggest", "```agent", "Run:", "```", "", "```sh %", "# ⚙", "for f in a b; do",
    "  echo $f", "done", "```" })
end

T["re-running `>` replaces the whole previous run, but not your own cells"] = function()
  boot({ "> suggest" })
  child.lua("vim.env.FAKE_PI_REPLY = ...", { "A\n```sh %\nls\n```\nB" })
  H.run(child, 1)
  child.lua("vim.api.nvim_buf_set_lines(0, -1, -1, false, { '', '% echo mine' })")
  H.run(child, 1)
  eq(H.lines(child), { "> suggest", "```agent", "A", "B", "```", "", "% ls  # ⚙", "", "% echo mine" })
end

return T
