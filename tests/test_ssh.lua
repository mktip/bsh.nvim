-- The real ssh route, end to end, against tests/bin/ssh: a stand-in that joins
-- its words and hands them to a shell, as ssh does. What's checked is that what
-- bsh sends survives that re-parse (quotes, $, backticks, backslashes,
-- unicode) for every kind of cell, and that big blocks get through.
local H = require("tests.helpers")
local eq = MiniTest.expect.equality
local child = H.child()
local T = H.set(child)

local function boot(lines)
  H.bootstrap(child, { lines = lines })
  child.lua("vim.env.PATH = vim.fn.getcwd() .. '/tests/bin:' .. vim.env.PATH")
end

-- the body of the (last) out fence
local function out()
  local l, from = H.lines(child), nil
  for i, s in ipairs(l) do if s == "```out" then from = i end end
  local body = {}
  for i = (from or #l) + 1, #l do
    if l[i] == "```" then break end
    body[#body + 1] = l[i]
  end
  return body
end

local function block(hdr, body)
  local t = { "```" .. hdr }
  vim.list_extend(t, body)
  t[#t + 1] = "```"
  return t
end

-- python that prints a string with everything a shell would mangle
local PY = { [[s = 'a "q" $HOME `date` \\ ${x} %s !!' + " it's"]], "print(s)", [[print("ünï ✓")]] }
local PY_OUT = { [[a "q" $HOME `date` \ ${x} %s !! it's]], "ünï ✓" }

T["a % line over ssh: quotes and $ arrive as written"] = function()
  boot({ [[me@box% echo 'it'"'"'s' "$((1+2))" '$HOME' ünï]] })
  H.run(child, 1)
  eq(out(), { "it's 3 $HOME ünï" })
end

T["a ```% block over ssh, and a login shell without remote_login"] = function()
  boot(block("me@box%", { [[x='a b']], [[printf '%s|\n' "$x" 'c\d']] }))
  H.run(child, 1)
  eq(out(), { "a b|", [[c\d|]] })
  child.lua("require('bsh').remote_login = false")
  H.run(child, 1)
  eq(out(), { "a b|", [[c\d|]] })
end

T["```python me@box% and %%: the program arrives intact"] = function()
  boot(block("python me@box%", PY))
  H.run(child, 1)
  eq(out(), PY_OUT)
  boot(block("python me@box%%", PY))
  H.run(child, 1)
  eq(out(), PY_OUT)
end

T["a ```lang % block of yours over ssh"] = function()
  boot(block("shx me@box%", { [[echo "$((6*7))" '$x']] }))
  child.lua([[require('bsh').setup({ languages = { shx = { cmd = "sh", print = "echo %s" } } })]])
  H.run(child, 1)
  eq(out(), { "42 $x" })
end

T["a 170KB ```python % block runs, here and over ssh (no argument-size limit)"] = function()
  local big = { "x = 0" }
  for i = 1, 4000 do big[#big + 1] = ("x += %d  # padding padding padding padding"):format(i) end
  big[#big + 1] = "print('big', x)"
  for _, route in ipairs({ "", "me@box" }) do
    boot(block("python " .. route .. "%", big))
    H.run(child, 1)
    eq(out(), { "big 8002000" })
  end
end

T["a process that can't start says so in its cell (not `...running...` forever)"] = function()
  boot({ "nope@x% echo hi", "", "```%" })
  child.lua([[require('bsh').transports.nope = { "/no/such/binary", "{addr}", "{cmd}" }]])
  H.run(child, 1)
  eq(out()[1]:match("^%[couldn't start: .*not executable") ~= nil, true)
  -- an over-long shell block: the argument limit, with what to do about it
  local lines = { "```%" }
  for i = 1, 6000 do lines[#lines + 1] = "# padding padding padding padding " .. i end
  lines[#lines + 1] = "```"
  boot(lines)
  H.run(child, 1)
  eq(out()[1]:match("^%[couldn't start: the block is too big") ~= nil, true)
end

return T
