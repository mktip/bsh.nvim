-- bsh.cell: the line grammar every part of bsh shares, and user rules
-- (config.rules) that add cell kinds of your own.
local H = require("tests.helpers")
local eq = MiniTest.expect.equality
local child = H.child()
local T = H.set(child)

local function parse(line)
  local c = child.lua_get("require('bsh.cell').parse(...) or vim.NIL", { line })
  return c ~= vim.NIL and c or nil
end

T["shell cells: one-shot, session, routed, nested route"] = function()
  H.bootstrap(child)
  eq(parse("% ls -l"), { kind = "shell", prefix = "% ", indent = "", target = "", session = false, body = "ls -l" })
  eq(parse("  %% cd /tmp").session, true)
  eq(parse("  %% cd /tmp").indent, "  ")
  local c = parse("me@server/docker@api%% ps aux")
  eq({ c.target, c.session, c.body, c.prefix }, { "me@server/docker@api", true, "ps aux", "me@server/docker@api%% " })
end

T["the marker comes from config"] = function()
  H.bootstrap(child)
  child.lua("require('bsh').marker = '$'")
  eq(parse("$ ls").kind, "shell")
  eq(parse("% ls"), nil)
end

T["agent cells: arrows, bang, template"] = function()
  H.bootstrap(child)
  local c = parse("> hi there")
  eq({ c.kind, c.stateful, c.bang, c.body, c.prefix }, { "agent", false, false, "hi there", "> " })
  c = parse("[gemma]>>! fix it")
  eq({ c.template, c.stateful, c.bang, c.body, c.prefix }, { "gemma", true, true, "fix it", "[gemma]>>! " })
end

T["listings, urls, namespace, and prose"] = function()
  H.bootstrap(child)
  eq(parse(": ~/src -T").body, "~/src -T")
  eq(parse("me@host: /var/log").target, "me@host")
  eq(parse("https://example.com").url, "https://example.com")
  eq(parse("demo.weather!").kind, "nsedit")
  local c = parse("demo.weather Ankara | tr a-z A-Z")
  eq({ c.kind, c.name, c.args }, { "ns", "demo.weather", "Ankara | tr a-z A-Z" })
  eq(parse("TODO: fix"), nil)  -- prose: not a listing (no route before the colon)
  eq(parse("note to self").kind, "ns") -- tentative: a cell only if `note` resolves
  eq(parse("- a list item"), nil)
  eq(parse(""), nil)
end

T["a user rule returning a command runs it as a % cell"] = function()
  H.bootstrap(child, { lines = { "ticket ABC-12" } })
  child.lua([[require('bsh').setup({ rules = {
    { match = "^ticket (%u+)%-(%d+)$", run = function(ctx, proj, n)
        return "echo " .. proj .. " " .. n .. " at row " .. ctx.row end },
  } })]])
  H.run(child, 1)
  eq(H.lines(child), { "ticket ABC-12", "```out", "ABC 12 at row 0", "```" })
end

T["a user rule can handle the line itself, or pass with false"] = function()
  H.bootstrap(child, { lines = { "ping", "% echo builtin" } })
  child.lua([[require('bsh').setup({ rules = {
    { match = "^ping$", run = function() _G.pinged = true end },
    { match = "^%% echo", run = function() return false end },
  } })]])
  H.run(child, 1)
  eq(child.lua_get("_G.pinged"), true)
  eq(H.lines(child)[2], "% echo builtin") -- handled, nothing written
  H.run(child, 2)
  eq(vim.list_slice(H.lines(child), 2), { "% echo builtin", "```out", "builtin", "```" })
end

return T
