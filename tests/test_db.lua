-- `db` namespace command: a faceted ndb browser (menu -> entries -> fields, each
-- drill an ANDed `attr=value` filter). Needs plan9port's `ndbquery` on PATH; the
-- whole set skips cleanly where it isn't installed (CI without plan9port).
local H = require("tests.helpers")
local eq = MiniTest.expect.equality
local child = H.child()
local T = H.set(child)

local have_ndb = vim.fn.executable("ndbquery") == 1
if not have_ndb then
  T["ndbquery present"] = function() MiniTest.skip("ndbquery (plan9port) not installed") end
  return T
end

T["db lists the ndb files as a menu"] = function()
  H.bootstrap(child, { name = "db.bsh", lines = { "db" } })
  H.run(child, 1)
  eq(H.lines(child), { "db", "```menu", "hosts", "```" })
end

T["drill a file -> entries; drill an entry -> its fields"] = function()
  H.bootstrap(child, { name = "db.bsh", lines = { "db" } })
  H.run(child, 1)
  H.run(child, H.rowof(child, "^hosts$")) -- -> entry list
  eq(H.lines(child)[1], "db 'hosts'")
  eq(H.rowof(child, "^sys=server$") ~= nil, true)

  H.run(child, H.rowof(child, "^sys=server$")) -- -> server's fields
  eq(H.lines(child)[1], "db 'hosts' 'sys=server'")
  eq(H.rowof(child, "^role=fileserver$") ~= nil, true)
  eq(H.rowof(child, "^ip=192%.168%.1%.10$") ~= nil, true)
end

T["drilling a second field AND-narrows the filter stack"] = function()
  H.bootstrap(child, { name = "db.bsh", lines = { "db hosts owner=mara" } })
  H.run(child, 1) -- two entries share owner=mara
  eq(H.rowof(child, "^sys=laptop$") ~= nil, true)
  eq(H.rowof(child, "^sys=phone$") ~= nil, true)

  H.run(child, H.rowof(child, "^sys=phone$")) -- AND sys=phone -> just the phone
  eq(H.lines(child)[1], "db hosts owner=mara 'sys=phone'")
  eq(H.rowof(child, "^ip=192%.168%.1%.21$") ~= nil, true)
  eq(H.rowof(child, "^sys=laptop$"), vim.NIL) -- laptop narrowed out (absent)
end

return T
