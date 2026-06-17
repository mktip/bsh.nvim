-- Side-buffer output (<C-CR>/g<CR>): the log reference fence, the buffer's
-- contents, reuse/sticky, open-on-<CR>, and session routing.
local H = require("tests.helpers")
local eq = MiniTest.expect.equality
local child = H.child()
local T = H.set(child)

-- contents of the side buffer linked from the doc's LAST `log` fence
local function side_lines()
  return child.lua_get([[(function()
    local last
    for _, l in ipairs(vim.api.nvim_buf_get_lines(0,0,-1,false)) do
      last = l:match('bsh://out/%S+') or last
    end
    if last then return vim.api.nvim_buf_get_lines(vim.fn.bufnr(last), 0, -1, false) end
  end)()]])
end

T["g<CR> leaves a log reference fence and fills a side buffer"] = function()
  H.bootstrap(child, { name = "play.bsh", lines = { "$ printf 'a\\nb\\n'" } })
  H.run(child, 1, true) -- to_buf
  local doc = H.lines(child)
  eq(doc[1], "$ printf 'a\\nb\\n'")
  eq(doc[2], "```log")
  eq(doc[3]:match("^bsh://out/play%.bsh/%d+") ~= nil, true)
  eq(doc[3]:match("exit 0") ~= nil, true)
  eq(side_lines(), { "a", "b" })
end

T["re-run reuses the linked buffer (sticky, no new buffer)"] = function()
  H.bootstrap(child, { name = "p.bsh", lines = { "$ echo hi" } })
  H.run(child, 1, true)
  local link1 = child.lua_get("vim.api.nvim_buf_get_lines(0,2,3,false)[1]:match('bsh://out/%S+')")
  local nbufs1 = child.lua_get("#vim.api.nvim_list_bufs()")
  H.run(child, 1, false) -- plain <CR> stays routed (sticky) and reuses
  local link2 = child.lua_get("vim.api.nvim_buf_get_lines(0,2,3,false)[1]:match('bsh://out/%S+')")
  local nbufs2 = child.lua_get("#vim.api.nvim_list_bufs()")
  eq(link1, link2)
  eq(nbufs1, nbufs2)
end

T["<CR> on the reference line opens the output buffer"] = function()
  H.bootstrap(child, { name = "o.bsh", lines = { "$ echo open-me" } })
  H.run(child, 1, true)
  H.run(child, 3) -- the reference line
  eq(child.lua_get("vim.api.nvim_buf_get_name(0):match('bsh://out/') ~= nil"), true)
end

T["python $$ to buffer: state persists, each cell its own buffer"] = function()
  H.bootstrap(child, {
    name = "sp.bsh",
    lines = { "```python $$", "r = 7", "```", "", "```python $$", "print('r*r =', r*r)", "```" },
  })
  H.run(child, H.rowof(child, "^r = 7$"), true)
  H.run(child, H.rowof(child, "print%('r%*r"), true)
  eq(side_lines(), { "r*r = 49" }) -- side_lines returns the LAST log fence's buffer
end

return T
