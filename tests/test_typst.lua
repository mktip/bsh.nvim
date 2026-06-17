-- `.bsh.typ` (typst mode): the run marker is `%`/`%%` and the owned result is a
-- `#cell(...)` ELEMENT (structured fields -> a typeset card), not an ```out fence.
local H = require("tests.helpers")
local eq = MiniTest.expect.equality
local child = H.child()
local T = H.set(child)

T["% runs into an owned #cell element"] = function()
  H.bootstrap(child, { typst = true, lines = { "% echo hello" } })
  H.run(child, 1)
  eq(H.lines(child), {
    "% echo hello",
    '#cell(cmd: "echo hello", host: none, cwd: ' .. child.lua_get(
      "'\"' .. vim.fn.fnamemodify(vim.fn.getcwd(), ':~') .. '\"'"
    ) .. ", code: 0)[```",
    "hello",
    "```]",
  })
end

T["a failing % records its exit code in the opener"] = function()
  H.bootstrap(child, { typst = true, lines = { "% sh -c 'exit 3'" } })
  H.run(child, 1)
  -- opener carries code: 3 (rewritten post-run via finalize)
  eq(H.rowof(child, "^#cell%(.*code: 3%)%[```$") ~= nil, true)
end

T["a routed % puts the host in the opener and keeps the command inert"] = function()
  -- no ssh needed: build_argv runs `ssh -T host ...` which fails fast, but the
  -- STAGED opener (host + cmd fields) is what we assert -- it's written up front.
  H.bootstrap(child, { typst = true, lines = { "web@prod% grep -c '$' /etc/passwd" } })
  H.run(child, 1)
  eq(H.rowof(child, '^#cell%(cmd: "grep %-c .\\$. /etc/passwd", host: "web@prod"') ~= nil, true)
end

T["re-running replaces the #cell body (idempotent)"] = function()
  H.bootstrap(child, { typst = true, lines = { "% echo one" } })
  H.run(child, 1)
  child.lua("vim.api.nvim_buf_set_lines(0, 0, 1, false, { '% echo two' })")
  H.run(child, 1)
  eq(H.rowof(child, "^two$") ~= nil, true)
  eq(H.rowof(child, "^one$"), vim.NIL) -- old output gone, not duplicated
  -- exactly one #cell opener and one closer
  eq(child.lua_get([[(function()
    local o = 0 for _, l in ipairs(vim.api.nvim_buf_get_lines(0,0,-1,false)) do
      if l:match("^#cell%(") then o = o + 1 end end return o end)()]]), 1)
end

return T
