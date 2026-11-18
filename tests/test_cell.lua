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
  local function parse(line)
    return child.lua_get("require('bsh.contrib.agent').parse(...)", { line })
  end
  local c = parse("> hi there")
  eq({ c.stateful, c.bang, c.body, c.prefix }, { false, false, "hi there", "> " })
  eq(child.lua_get("require('bsh.cell').rule_for('> hi').name"), "agent")
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

-- A cell kind of your own with the whole rule API: its own fence (ctx.run),
-- <M-CR> continuation (prompt), visual-selection context, and ]c / [c.
local SQL_RULE = [[require('bsh').setup({ rules = { {
  match = "^sql> (.+)$",
  prompt = function() return "sql> " end,
  tag = "rows",
  run = function(ctx, q)
    local sel = ctx.selection and table.concat(ctx.selection, ",") or "-"
    ctx.run({ "sh", "-c", "printf '%s\\n' \"$1\" \"sel=$2\" '```x'", "_", q, sel },
      { on_done = function(a, b) _G.done = { a, b } end })
  end,
} } })]]

T["a rule streams into its own fence via ctx.run"] = function()
  H.bootstrap(child, { lines = { "sql> select 1" } })
  child.lua(SQL_RULE)
  H.run(child, 1)
  -- ``` in the output is neutralised so it can't close the fence early
  eq(H.lines(child), { "sql> select 1", "```rows", "select 1", "sel=-", "'''x", "```" })
  eq(child.lua_get("_G.done"), { 2, 5 })
  H.run(child, 1) -- a re-run replaces its fence (the tag is owned)
  eq(#H.lines(child), 6)
end

T["a rule gets the visual selection, and <M-CR> / ]c know it"] = function()
  H.bootstrap(child, { lines = { "a", "b", "sql> q" } })
  child.lua(SQL_RULE)
  child.lua([[
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('Vjj<CR>', true, false, true), 'x', false)
    vim.wait(2000, function() return vim.api.nvim_buf_get_lines(0, 5, 6, false)[1] == 'sel=a,b' end)
  ]])
  eq(vim.list_slice(H.lines(child), 3, 6), { "sql> q", "```rows", "q", "sel=a,b" })
  child.lua([[vim.api.nvim_win_set_cursor(0, { 1, 0 }); vim.cmd('normal ]c')]])
  eq(child.lua_get("vim.fn.line('.')"), 3)
  child.lua([[
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<M-CR>next<Esc>', true, false, true), 'x', false)
  ]])
  eq(vim.list_slice(H.lines(child), 8), { "```", "", "sql> next" })
end

T["your own rule can take over `>`; agent = false frees it"] = function()
  H.bootstrap(child)
  eq(child.lua_get("require('bsh.cell').rule_for('> hi').name"), "agent")
  child.lua([[require('bsh').setup({ rules = { { name = "mine", match = "^> (.*)$", run = function() end } } })]])
  eq(child.lua_get("require('bsh.cell').rule_for('> hi').name"), "mine")
  child.lua([[require('bsh').setup({ rules = {}, agent = false })]])
  eq(child.lua_get("require('bsh.cell').rule_for('> hi')"), vim.NIL)
end

return T
