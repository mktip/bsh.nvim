-- Pluggable languages (config.languages): ```lang % once, ```lang %% as a
-- persistent process, with prompt / echo / banner noise cleaned out.
local H = require("tests.helpers")
local eq = MiniTest.expect.equality
local child = H.child()
local T = H.set(child)

local function done()
  child.lua([[vim.wait(5000, function() return not next(require('bsh.fence').inflight[vim.api.nvim_get_current_buf()] or {}) end, 10)
    vim.wait(200)]])
end

local function run(row)
  child.lua("vim.api.nvim_win_set_cursor(0, { ..., 0 })", { row })
  child.lua("vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<CR>', true, false, true), 'x', false)")
  done()
end

-- a noisy REPL: a banner, a "> " prompt, and every input line echoed back
local NOISY = [[sh -c 'echo "NoisyREPL 1.0"; while printf "> "; IFS= read -r l; do printf "%s\n" "$l"; eval "$l"; done']]

T["a language runs once (block on stdin) and as a session that keeps state"] = function()
  H.bootstrap(child, { lines = { "```shx %", "echo $((2 + 3))", "```", "", "```shx %%", "X=7", "```", "",
    "```shx %%", "echo got $X", "```" } })
  child.lua([[require('bsh').setup({ languages = { shx = { cmd = "sh", print = "echo %s" } } })]])
  run(2); run(H.rowof(child, "^X=7$")); run(H.rowof(child, "^echo got"))
  local L = H.lines(child)
  eq(vim.list_slice(L, 1, 6), { "```shx %", "echo $((2 + 3))", "```", "```out", "5", "```" })
  eq(L[#L - 1], "got 7")
end

T["prompt, echo and the startup banner are cleaned out of a REPL's output"] = function()
  H.bootstrap(child, { lines = { "```noisy %%", "A=hello", "```", "", "```noisy %%", "echo $A", "echo two", "```" } })
  child.lua("require('bsh').setup({ languages = { noisy = { cmd = 'sh', session = ..., print = 'echo %s', prompt = '> ', echo = true } } })",
    { NOISY })
  run(2); run(H.rowof(child, "^echo %$A$"))
  eq(H.lines(child), { "```noisy %%", "A=hello", "```", "```out", "(no output)", "```", "",
    "```noisy %%", "echo $A", "echo two", "```", "```out", "hello", "two", "```" })
end

T["a language works along a route"] = function()
  H.bootstrap(child, { lines = { "```shx loc@x%%", "echo routed", "```" } })
  child.lua([[require('bsh').setup({ transports = { loc = { "sh", "-c", "{cmd}" } },
    languages = { shx = { cmd = "sh", print = "echo %s" } } })]])
  run(2)
  eq(H.lines(child)[5], "routed")
end

T["an unknown language word stays an inert block"] = function()
  H.bootstrap(child, { lines = { "```ruby %", "puts 1", "```" } })
  run(2)
  eq(#H.lines(child), 3)
end

return T
