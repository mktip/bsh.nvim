-- `: path -T` fold-tree listing: collapsed by default, expands/collapses one
-- node in place (siblings untouched), `../` still walks up, `-H` propagates
-- into child expansions. See the fold-tree plan for the line format.
local H = require("tests.helpers")
local eq = MiniTest.expect.equality
local child = H.child()
local T = H.set(child)

-- A small fixture tree:
--   <tmp>/docs/notes.txt
--   <tmp>/src/main.lua
--   <tmp>/src/lib/util.lua
--   <tmp>/Makefile
--   <tmp>/README.md
--   <tmp>/.env            (hidden)
local function make_tree()
  local tmp = child.lua_get("vim.fn.tempname()")
  child.lua(
    [[
    local tmp = ...
    vim.fn.mkdir(tmp .. '/docs', 'p')
    vim.fn.mkdir(tmp .. '/src/lib', 'p')
    vim.fn.writefile({}, tmp .. '/docs/notes.txt')
    vim.fn.writefile({}, tmp .. '/src/main.lua')
    vim.fn.writefile({}, tmp .. '/src/lib/util.lua')
    vim.fn.writefile({}, tmp .. '/Makefile')
    vim.fn.writefile({}, tmp .. '/README.md')
    vim.fn.writefile({}, tmp .. '/.env')
  ]],
    { tmp }
  )
  return tmp
end

T["initial -T render: collapsed dirs first, then files, no recursion"] = function()
  local tmp = make_tree()
  H.bootstrap(child, { lines = { ": " .. tmp .. " -T" } })
  H.run(child, 1)
  eq(H.lines(child), {
    ": " .. tmp .. " -T",
    "```tree",
    "../",
    "▸ docs/",
    "▸ src/",
    "Makefile",
    "README.md",
    "```",
  })
end

T["expanding a node splices its children in, flips the marker, siblings untouched"] = function()
  local tmp = make_tree()
  H.bootstrap(child, { lines = { ": " .. tmp .. " -T" } })
  H.run(child, 1)
  H.run(child, H.rowof(child, "▸ docs/"))
  eq(H.lines(child), {
    ": " .. tmp .. " -T",
    "```tree",
    "../",
    "▾ docs/",
    "  notes.txt",
    "▸ src/", -- untouched sibling: still collapsed, still there
    "Makefile",
    "README.md",
    "```",
  })
end

T["collapsing removes exactly the spliced children and flips the marker back"] = function()
  local tmp = make_tree()
  H.bootstrap(child, { lines = { ": " .. tmp .. " -T" } })
  H.run(child, 1)
  H.run(child, H.rowof(child, "▸ docs/")) -- expand
  H.run(child, H.rowof(child, "▾ docs/")) -- collapse again
  eq(H.lines(child), {
    ": " .. tmp .. " -T",
    "```tree",
    "../",
    "▸ docs/",
    "▸ src/",
    "Makefile",
    "README.md",
    "```",
  })
end

T["a nested dir expands at depth 2, a nested file opens with the reconstructed path"] = function()
  local tmp = make_tree()
  H.bootstrap(child, { lines = { ": " .. tmp .. " -T" } })
  H.run(child, 1)
  H.run(child, H.rowof(child, "▸ src/")) -- expand src/ -> lib/ (dir) + main.lua (file)
  eq(H.lines(child), {
    ": " .. tmp .. " -T",
    "```tree",
    "../",
    "▸ docs/",
    "▾ src/",
    "  ▸ lib/",
    "  main.lua",
    "Makefile",
    "README.md",
    "```",
  })

  H.run(child, H.rowof(child, "▸ lib/")) -- expand nested lib/ at depth 2
  eq(H.lines(child), {
    ": " .. tmp .. " -T",
    "```tree",
    "../",
    "▸ docs/",
    "▾ src/",
    "  ▾ lib/",
    "    util.lua",
    "  main.lua",
    "Makefile",
    "README.md",
    "```",
  })

  H.run(child, H.rowof(child, "^%s*main%.lua$")) -- open the depth-1 file
  eq(child.lua_get("vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ':p')"), tmp .. "/src/main.lua")
end

T["../ still walks up and re-lists at depth 0"] = function()
  local tmp = make_tree()
  H.bootstrap(child, { lines = { ": " .. tmp .. "/src" .. " -T" } })
  H.run(child, 1)
  H.run(child, H.rowof(child, "^%.%./$"))
  eq(H.lines(child), {
    ": " .. tmp .. " -T",
    "```tree",
    "../",
    "▸ docs/",
    "▸ src/",
    "Makefile",
    "README.md",
    "```",
  })
end

T["-H propagates into child expansions"] = function()
  local tmp = make_tree()
  H.bootstrap(child, { lines = { ": " .. tmp .. " -H -T" } })
  H.run(child, 1)
  eq(H.lines(child), {
    ": " .. tmp .. " -H -T",
    "```tree",
    "../",
    "▸ docs/",
    "▸ src/",
    ".env",
    "Makefile",
    "README.md",
    "```",
  })
end

return T
