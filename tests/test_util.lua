-- Pure-function unit tests for bsh.util -- run in-process (no child Neovim), so
-- they're fast and exercise the parsing logic directly.
local util = require("bsh.util")
local eq = MiniTest.expect.equality
local T = MiniTest.new_set()

T["parse_runmarker"] = MiniTest.new_set()
T["parse_runmarker"]["bare $ / $$ are shell"] = function()
  eq({ util.parse_runmarker("$") }, { "sh", "", false })
  eq({ util.parse_runmarker("$$") }, { "sh", "", true })
end
T["parse_runmarker"]["a remote target is captured"] = function()
  eq({ util.parse_runmarker("user@host$") }, { "sh", "user@host", false })
  eq({ util.parse_runmarker("user@host$$") }, { "sh", "user@host", true })
end
T["parse_runmarker"]["language-prefixed forms"] = function()
  eq({ util.parse_runmarker("python $") }, { "python", "", false })
  eq({ util.parse_runmarker("py $$") }, { "python", "", true })
  eq({ util.parse_runmarker("bash $") }, { "sh", "", false })
end
T["parse_runmarker"]["no marker / unknown lang -> inert (nil)"] = function()
  eq({ util.parse_runmarker("out") }, {})
  eq({ util.parse_runmarker("python") }, {})
  eq({ util.parse_runmarker("ruby $") }, {}) -- ruby not yet a known engine
end

T["parse_list_args"] = MiniTest.new_set()
T["parse_list_args"]["peels -T and -H, keeps the path"] = function()
  eq({ util.parse_list_args("~/x -T") }, { "~/x", { tree = true, hidden = false } })
  eq({ util.parse_list_args("~/x -H -T") }, { "~/x", { tree = true, hidden = true } })
  eq({ util.parse_list_args("") }, { ".", { tree = false, hidden = false } })
end

T["join_path"] = MiniTest.new_set()
T["join_path"]["joins, normalises, walks up on .."] = function()
  eq(util.join_path("/a/b", "c"), "/a/b/c")
  eq(util.join_path("/a/b/", "c"), "/a/b/c")
  eq(util.join_path("/a/b", ".."), "/a")
end

return T
