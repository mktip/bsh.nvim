-- `%%` persistent shell sessions: state carries across cells, the cwd badge
-- rides the shell's own $PWD, and a session composes over the route engine (so
-- any user-defined transport gets persistent sessions, not just ssh).
local H = require("tests.helpers")
local eq = MiniTest.expect.equality
local child = H.child()
local T = H.set(child)

-- The cwd badge's virt_text on row `r0` (0-indexed), concatenated, or "" if none.
local function badge(r0)
  return child.lua_get(
    [[(function(r)
      local pns = vim.api.nvim_create_namespace('bsh_prompt')
      local ms = vim.api.nvim_buf_get_extmarks(0, pns, { r, 0 }, { r, -1 }, { details = true })
      local out = {}
      for _, m in ipairs(ms) do
        for _, chunk in ipairs((m[4] or {}).virt_text or {}) do out[#out + 1] = chunk[1] end
      end
      return table.concat(out)
    end)(...)]],
    { r0 }
  )
end

T["%% is one shell: env carries across cells"] = function()
  H.bootstrap(child, { name = "s.bsh", lines = { "%% X=hi", "", "%% echo $X" } })
  H.run(child, H.rowof(child, "^%%%% X=hi$"))
  H.run(child, H.rowof(child, "echo %$X")) -- re-locate: the first run shifted it down
  eq(H.rowof(child, "^hi$") ~= nil, true)
end

T["the cwd badge tracks the shell's $PWD (no `cd` parsing)"] = function()
  H.bootstrap(child, { name = "c.bsh", lines = { "%% cd /tmp", "", "%% pwd" } })
  child.lua("require('bsh.config').prompt_badge = true") -- the badge is opt-in
  H.run(child, H.rowof(child, "cd /tmp"))
  H.run(child, H.rowof(child, "^%%%% pwd$"))
  -- `pwd` confirms the session really moved; the badge mirrors it on the cell line
  eq(H.rowof(child, "^/tmp$") ~= nil, true)
  eq(badge(0):find("/tmp", 1, true) ~= nil, true) -- badge on the `cd /tmp` cell (row 0)
end

T["a session composes over a user-defined transport"] = function()
  H.bootstrap(child, { name = "t.bsh", lines = { "loc@x%% Y=ok", "", "loc@x%% echo $Y" } })
  -- `loc` is a transport that just runs a shell locally -> exercises build_argv's
  -- route path end-to-end (the same path docker/jail/ssh take) without a network.
  child.lua("require('bsh').transports.loc = { 'sh', '-lc', '{cmd}' }")
  child.lua("require('bsh.config').prompt_badge = true") -- the badge is opt-in
  H.run(child, H.rowof(child, "Y=ok"))
  H.run(child, H.rowof(child, "echo %$Y"))
  eq(H.rowof(child, "^ok$") ~= nil, true)
  eq(badge(0):find("loc@x:", 1, true) ~= nil, true) -- badge shows the route as a prompt
end

T["a one-shot python cell routes over a transport (`python loc@x%`)"] = function()
  H.bootstrap(child, { name = "rp.bsh", lines = { "```python loc@x%", "print('oneshot')", "```" } })
  child.lua("require('bsh').transports.loc = { 'sh', '-lc', '{cmd}' }")
  H.run(child, H.rowof(child, "print%('oneshot'%)"))
  eq(H.rowof(child, "^oneshot$") ~= nil, true)
end

T["python %% composes over a transport: globals persist (`python loc@x%%`)"] = function()
  H.bootstrap(child, {
    name = "rps.bsh",
    lines = { "```python loc@x%%", "g = 6", "```", "", "```python loc@x%%", "print('g*g =', g*g)", "```" },
  })
  -- the same route path as the sh session, but the python DRIVER is what's run on
  -- the far side -- its length-prefixed stdin protocol flowing over the transport.
  child.lua("require('bsh').transports.loc = { 'sh', '-lc', '{cmd}' }")
  H.run(child, H.rowof(child, "^g = 6$"))
  H.run(child, H.rowof(child, "print%('g%*g"))
  eq(H.rowof(child, "^g%*g = 36$") ~= nil, true)
end

-- True iff a buffer line matches Lua pattern `pat`. (H.rowof returns vim.NIL, not
-- nil, for "no match" across the RPC boundary, so `rowof(..) ~= nil` can't fail.)
local function has(pat)
  return child.lua_get(
    [[(function(p)
      for _, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
        if l:match(p) then return true end
      end
      return false
    end)(...)]],
    { pat }
  )
end

-- A cell's stdin is NOT the session's command channel: a command that reads stdin
-- (`mpirun`, a bare `cat`) used to inherit the pipe, eat the sentinel queued behind
-- it and hang the session until killed.
T["a cell that reads stdin gets EOF instead of hanging the session"] = function()
  H.bootstrap(child, { name = "in.bsh", lines = { "%% cat", "", "%% echo after" } })
  H.run(child, H.rowof(child, "^%%%% cat$"))
  eq(has("no output"), true) -- cat saw EOF and returned
  H.run(child, H.rowof(child, "echo after"))
  eq(has("^after$"), true) -- the session is still responsive
end

T["an explicit `<` redirect still feeds a cell's stdin"] = function()
  H.bootstrap(child, { name = "redir.bsh", lines = { "%% printf 'from-file\\n' > /tmp/bsh_in_$$", "", "%% cat < /tmp/bsh_in_$$", "", "%% printf 'a\\nb\\n' | wc -l" } })
  H.run(child, H.rowof(child, "> /tmp/bsh_in"))
  H.run(child, H.rowof(child, "cat < /tmp/bsh_in"))
  eq(has("^from%-file$"), true)
  H.run(child, H.rowof(child, "wc %-l"))
  eq(has("^2$"), true)
end

T["Ctrl-C (interrupt_session) still interrupts a running cell and keeps the session"] = function()
  H.bootstrap(child, { name = "int.bsh", lines = { "%% X=kept", "", "%% sleep 20", "", "%% echo $X" } })
  H.run(child, H.rowof(child, "^%%%% X=kept$"))
  child.lua([[
    local row = ...
    vim.api.nvim_win_set_cursor(0, { row, 0 })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<CR>', true, false, true), 'x', false)
    vim.wait(300)
  ]], { H.rowof(child, "sleep 20") }) -- re-located: the first run's fence shifted it
  eq(child.lua_get("require('bsh.session').interrupt_session(vim.api.nvim_get_current_buf(), 'sh', '')"), true)
  child.lua("vim.wait(800)")
  eq(has("%[exit 130%]"), true) -- SIGINT reached the child, not the driver
  H.run(child, H.rowof(child, "echo %$X"))
  eq(has("^kept$"), true) -- same shell: env survived the interrupt
end

-- `%%` streams like `%`: output shows up while the cell is still running, not in
-- one dump at the end.
T["%% streams partial output while the cell is still running"] = function()
  H.bootstrap(child, { name = "st.bsh", lines = { "%% for i in 1 2 3; do echo line$i; sleep 1; done" } })
  child.lua([[
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<CR>', true, false, true), 'x', false)
    vim.wait(1500) -- line1 is out; line3 is >= 2s away
  ]])
  eq(has("^line1$"), true) -- painted while still running...
  eq(has("^line3$"), false) -- ...before the cell finished
  child.lua([[
    vim.wait(4000, function()
      return vim.tbl_contains(vim.api.nvim_buf_get_lines(0, 0, -1, false), 'line3')
    end, 20)
    vim.wait(300) -- let the sentinel land and the final fill run
  ]])
  eq(child.lua_get("vim.api.nvim_buf_get_lines(0, 0, -1, false)"),
    { "%% for i in 1 2 3; do echo line$i; sleep 1; done", "```out", "line1", "line2", "line3", "```" })
end

T["%% streaming keeps a finished cell exact when re-run (no stale lines)"] = function()
  H.bootstrap(child, { name = "st2.bsh", lines = { "%% printf 'a\\nb\\nc\\n'" } })
  H.run(child, 1)
  H.run(child, 1)
  eq(child.lua_get("vim.api.nvim_buf_get_lines(0, 0, -1, false)"),
    { "%% printf 'a\\nb\\nc\\n'", "```out", "a", "b", "c", "```" })
end

return T
