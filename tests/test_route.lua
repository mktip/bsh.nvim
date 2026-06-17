-- Targets as routes: build_argv compiles `scheme@addr` hops (chained with `/`)
-- into the argv jobstart runs. These assert the COMPILED argv (a pure function of
-- target + config), so they need no ssh/docker/jail present.
local H = require("tests.helpers")
local eq = MiniTest.expect.equality
local child = H.child()
local T = H.set(child)

local function argv(target, cmd)
  return child.lua_get("require('bsh.job').build_argv(...)", { target, cmd })
end
local function esc(s)
  return child.lua_get("vim.fn.shellescape(...)", { s })
end

T["local target runs through the user's shell"] = function()
  H.bootstrap(child)
  eq(argv("", "ls -l"), {
    child.lua_get("vim.o.shell"), child.lua_get("vim.o.shellcmdflag"), "ls -l",
  })
end

T["a plain host is an ssh login-shell hop (back-compat)"] = function()
  H.bootstrap(child)
  eq(argv("web@prod", "ls"),
    { "ssh", "-T", "web@prod", "exec ${SHELL:-/bin/sh} -lc " .. esc("ls") })
end

T["remote_login=false drops the login wrapper"] = function()
  H.bootstrap(child)
  child.lua("require('bsh').remote_login = false")
  eq(argv("web@prod", "ls"), { "ssh", "-T", "web@prod", "ls" })
end

T["a docker hop execs in the container"] = function()
  H.bootstrap(child)
  eq(argv("docker@api", "ls -1p"), { "docker", "exec", "-i", "api", "sh", "-lc", "ls -1p" })
end

T["an unregistered scheme stays a plain ssh destination"] = function()
  H.bootstrap(child)
  eq(argv("k8s@pod", "ls"), -- k8s not registered by default -> ssh to host `k8s@pod`
    { "ssh", "-T", "k8s@pod", "exec ${SHELL:-/bin/sh} -lc " .. esc("ls") })
end

T["a user-defined transport is honoured"] = function()
  H.bootstrap(child)
  child.lua("require('bsh').transports.jail = { 'jexec', '{addr}', 'sh', '-lc', '{cmd}' }")
  eq(argv("jail@www", "ls"), { "jexec", "www", "sh", "-lc", "ls" })
end

T["a function transport gets (addr, inner)"] = function()
  H.bootstrap(child)
  child.lua("require('bsh').transports.fn = function(a, c) return { 'run', a, c } end")
  eq(argv("fn@x", "ls"), { "run", "x", "ls" })
end

T["a container over ssh nests (host first, then container)"] = function()
  H.bootstrap(child)
  local a = argv("web@prod/docker@api", "ls") -- outside-in: ssh host, then into container
  eq({ a[1], a[2], a[3] }, { "ssh", "-T", "web@prod" }) -- leftmost hop is the outer ssh one
  -- the command it runs on prod is the docker exec into api (each word is quoted
  -- by shelljoin, so assert the words are present rather than a literal substring)
  eq(child.lua_get([[(function(s)
    return s:find('docker', 1, true) and s:find('exec', 1, true) and s:find('api', 1, true) ~= nil
  end)(...)]], { a[4] }), true)
end

return T
