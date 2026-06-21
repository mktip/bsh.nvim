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

return T
