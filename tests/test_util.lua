-- Pure-function unit tests for bsh.util -- run in-process (no child Neovim), so
-- they're fast and exercise the parsing logic directly.
local util = require("bsh.util")
local eq = MiniTest.expect.equality
local T = MiniTest.new_set()

-- the marker is a parameter (config.marker), so the same logic works for any
-- symbol; default is `%`, and we prove `$` still works to lock in configurability.
T["parse_runmarker"] = MiniTest.new_set()
T["parse_runmarker"]["bare % / %% are shell"] = function()
  eq({ util.parse_runmarker("%", "%") }, { "sh", "", false })
  eq({ util.parse_runmarker("%%", "%") }, { "sh", "", true })
end
T["parse_runmarker"]["a remote target is captured"] = function()
  eq({ util.parse_runmarker("user@host%", "%") }, { "sh", "user@host", false })
  eq({ util.parse_runmarker("user@host%%", "%") }, { "sh", "user@host", true })
end
T["parse_runmarker"]["language-prefixed forms"] = function()
  eq({ util.parse_runmarker("python %", "%") }, { "python", "", false })
  eq({ util.parse_runmarker("py %%", "%") }, { "python", "", true })
  eq({ util.parse_runmarker("bash %", "%") }, { "sh", "", false })
end
T["parse_runmarker"]["no marker / unknown lang -> inert (nil)"] = function()
  eq({ util.parse_runmarker("out", "%") }, {})
  eq({ util.parse_runmarker("python", "%") }, {})
  eq({ util.parse_runmarker("ruby %", "%") }, {}) -- ruby not yet a known engine
end
T["parse_runmarker"]["the marker is configurable (e.g. back to $)"] = function()
  eq({ util.parse_runmarker("user@host$$", "$") }, { "sh", "user@host", true })
  eq({ util.parse_runmarker("user@host%%", "$") }, {}) -- % isn't the marker here
end

T["parse_list_args"] = MiniTest.new_set()
T["parse_list_args"]["peels -T and -H, keeps the path"] = function()
  eq({ util.parse_list_args("~/x -T") }, { "~/x", { tree = true, hidden = false } })
  eq({ util.parse_list_args("~/x -H -T") }, { "~/x", { tree = true, hidden = true } })
  eq({ util.parse_list_args("") }, { ".", { tree = false, hidden = false } })
end

T["fold_entry"] = MiniTest.new_set()
T["fold_entry"]["collapsed directory at depth 0"] = function()
  eq({ util.fold_entry("▸ src/") }, { 0, "src/", true, false })
end
T["fold_entry"]["expanded directory at depth 1 (2-space indent)"] = function()
  eq({ util.fold_entry("  ▾ lib/") }, { 1, "lib/", true, true })
end
T["fold_entry"]["collapsed directory at depth 2"] = function()
  eq({ util.fold_entry("    ▸ nested/") }, { 2, "nested/", true, false })
end
T["fold_entry"]["a file has no marker"] = function()
  eq({ util.fold_entry("README.md") }, { 0, "README.md", false, nil })
  eq({ util.fold_entry("  main.lua") }, { 1, "main.lua", false, nil })
end
T["fold_entry"]["blank/whitespace-only line -> nil"] = function()
  eq({ util.fold_entry("") }, {})
  eq({ util.fold_entry("   ") }, {})
end

T["join_path"] = MiniTest.new_set()
T["join_path"]["joins, normalises, walks up on .."] = function()
  eq(util.join_path("/a/b", "c"), "/a/b/c")
  eq(util.join_path("/a/b/", "c"), "/a/b/c")
  eq(util.join_path("/a/b", ".."), "/a")
end

return T
