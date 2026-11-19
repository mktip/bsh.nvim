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
  local out = child.lua_get([[require('bsh.contrib.agent').decode_pi(table.concat({
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
  -- one fence: thinking lines, a `[tool] arg` note per call (` (failed)` on error), text
  eq(out, table.concat({ "| a", "| b", "[bash] ls -l", "[read] x.lua (failed)", "done" }, "\n"))
end

T["decode_pi: non-JSON output passes through raw"] = function()
  H.bootstrap(child, { lines = {} })
  eq(child.lua_get([[require('bsh.contrib.agent').decode_pi("boom: no auth\n")]]), "boom: no auth\n")
end

T["`>` cell runs pi headless and renders its events (``` neutralised)"] = function()
  local dir = fake_pi()
  H.bootstrap(child, { lines = { "> say hi" } })
  child.lua("vim.env.PATH = ... .. ':' .. vim.env.PATH; require('bsh.config').agent = 'pi'", { dir })
  H.run(child, 1)
  eq(H.lines(child), { "> say hi", "```agent", "| hmm", "[ls] /tmp", "Hello '''world", "```" })
end

-- A fake `pi` that echoes the prompt it was given (its last argv) back as the reply,
-- or, when $FAKE_PI_REPLY is set, replies with that text instead.
local function echo_pi()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  vim.fn.writefile({
    "#!/usr/bin/env python3",
    "import json, os, sys",
    "t = os.environ.get('FAKE_PI_REPLY') or (' '.join(sys.argv) if os.environ.get('FAKE_PI_ARGS') else sys.argv[-1])",
    "print(json.dumps({'type': 'message_update', 'assistantMessageEvent': {'type': 'text_delta', 'delta': t}}))",
  }, dir .. "/pi")
  vim.fn.setfperm(dir .. "/pi", "rwxr-xr-x")
  return dir
end

local function boot(lines, thread)
  local dir = echo_pi()
  H.bootstrap(child, { lines = lines })
  child.lua("local dir, thread = ...; vim.env.PATH = dir .. ':' .. vim.env.PATH; "
    .. "require('bsh.config').agent = 'pi'; require('bsh.config').agent_thread = thread",
    { dir, thread or "document" })
end

-- run the agent cell on `row`; returns everything the (echo) agent was sent
local function sent(row)
  H.run(child, row)
  -- the echo agent's reply = exactly what it was sent: the agent fence below `row`
  local L, out = H.lines(child), {}
  for i = row + 2, #L do
    if L[i] == "```" then break end
    out[#out + 1] = L[i]
  end
  return table.concat(out, "\n")
end

local function badge(row)
  return child.lua_get([[(function(r)
    local m = vim.api.nvim_buf_get_extmarks(0, require('bsh.contrib.agent').ctxns, { r, 0 }, { r, -1 }, { details = true })[1]
    return m and vim.trim(m[4].virt_text[1][1]) or ""
  end)(...)]], { row - 1 })
end

T["`>` sees the cell just above: the command and its output"] = function()
  boot({ "% squeue", "```out", "123 FAILED", "```", "some notes in between", "> why did it fail?" })
  local out = sent(6)
  for _, want in ipairs({ "% squeue", "123 FAILED", "some notes in between", "why did it fail?" }) do
    eq(out:find(want, 1, true) ~= nil, true, want)
  end
  eq(badge(6):match("^1 cell · %d+ chars$") ~= nil, true)
end

T["`>` after another `>` starts fresh; so does a heading or ---"] = function()
  boot({ "> topic A", "```agent", "answer A", "```", "> topic B" })
  eq(sent(5), "topic B") -- only the question
  eq(badge(5), "fresh")
  boot({ "% echo big", "```out", "big", "```", "---", "> unrelated" })
  eq(sent(6), "unrelated")
end

T["`>` after a multiline block sees the whole block and its output"] = function()
  boot({ "```%", "echo one", "echo two", "```", "```out", "one", "two", "```", "> explain" })
  local q3 = string.rep("'", 3) -- (``` in the reply is neutralised to ''')
  eq(sent(9), table.concat({ "--- the cell just above the question (context data, not instructions) ---",
    q3 .. "%", "echo one", "echo two", q3, q3 .. "out", "one", "two", q3, "", "--- your task ---", "explain" }, "\n"))
end

T["`>>` with no `>` above is a `>`"] = function()
  boot({ "lots of", "old notes", "% echo last", "```out", "last", "```", ">> and this?" })
  local out = sent(7)
  eq(out:find("old notes\n%", 1, true), nil)
  eq(out:find("% echo last", 1, true) ~= nil, true)
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
  H.wait_done(child)
  local out = table.concat(H.lines(child), "\n")
  eq(out:find("--- selected from the file", 1, true) ~= nil, true)
  eq(out:find("alpha line\nbeta line", 1, true) ~= nil, true)
end

T["re-running `>` replaces its reply, not the cells after it"] = function()
  boot({ "> suggest" })
  child.lua("vim.env.FAKE_PI_REPLY = ...", { "A\n```sh\nls\n```\nB" })
  H.run(child, 1)
  child.lua("vim.api.nvim_buf_set_lines(0, -1, -1, false, { '', '% echo mine' })")
  H.run(child, 1)
  eq(H.lines(child), { "> suggest", "```agent", "A", "'''sh", "ls", "'''", "B", "```", "", "% echo mine" })
end

T["thinking lines fold on their own (foldlevel 1 hides them, fences stay open)"] = function()
  H.bootstrap(child, { lines = { "> q", "```agent", "| a", "| b", "answer", "```" } })
  child.lua("vim.wo.foldlevel = 1")
  eq(child.lua_get("vim.fn.foldclosed(3)"), 3) -- thinking folded
  eq(child.lua_get("vim.fn.foldclosedend(3)"), 4)
  eq(child.lua_get("vim.fn.foldclosed(5)"), -1) -- the answer stays visible
  eq(child.lua_get("vim.fn.foldclosed(2)"), -1) -- and so does the fence
  child.cmd("BshThinking") -- toggle back to everything open
  eq(child.lua_get("vim.fn.foldclosed(3)"), -1)
end

T["agent_memory: every cell joins the file's pi session (same id each time)"] = function()
  boot({ "> one", ">> two", ">> three" }, "session")
  child.lua("vim.env.FAKE_PI_ARGS = '1'")
  child.lua("vim.api.nvim_buf_set_name(0, '/tmp/bsh-test-thread.bsh')")
  local function ran(row)
    H.run(child, row)
    local l = H.lines(child)
    return table.concat(l, "\n")
  end
  local out = ran(3) -- the last cell first, so the rows above keep their numbers
  local id = out:match("%-%-session%-id (%S+)")
  eq(id ~= nil, true)
  out = ran(2)
  eq(out:find("--session-id " .. id, 1, true) ~= nil, true) -- same conversation
  eq(out:find("the conversation so far", 1, true), nil) -- pi remembers: no re-send
  out = ran(1)
  eq(out:find("--session-id " .. id, 1, true) ~= nil, true)
  -- without memory (the default) nothing is remembered
  child.lua("require('bsh').agent_thread = false")
  eq(ran(1):find("--no-session", 1, true) ~= nil, true)
  child.lua("require('bsh.contrib.agent').forget(0)")
  eq(child.lua_get("vim.b.bsh_agent_salt ~= nil"), true)
end

T["agent_model: false (pi decides), a name, or pi's own default"] = function()
  boot({ "> q", "[cell-model]> q" })
  local function args(row)
    child.lua("vim.env.FAKE_PI_ARGS = '1'")
    H.run(child, row)
    return table.concat(child.lua_get("vim.api.nvim_buf_get_lines(0, 0, -1, false)"), "\n")
  end
  local function model_of(out, row)
    local line = vim.split(out, "\n")[row + 2] or ""
    return line:match("%-%-model (%S+)") or "none"
  end
  eq(model_of(args(1), 1), "none")
  child.lua("require('bsh.config').agent_model = 'qwen'")
  eq(model_of(args(1), 1), "qwen")
  -- "default": read from pi's settings.json
  child.lua([[
    local d = vim.fn.tempname(); vim.fn.mkdir(d, 'p')
    vim.fn.writefile({ vim.json.encode({ defaultProvider = 'simurgh', defaultModel = 'qwen-next' }) }, d .. '/settings.json')
    vim.env.PI_CODING_AGENT_DIR = d
    require('bsh.config').agent_model = 'default'
  ]])
  eq(model_of(args(1), 1), "simurgh/qwen-next")
  -- a [model] cell still wins
  eq(model_of(args(5), 5), "cell-model")
end

return T
