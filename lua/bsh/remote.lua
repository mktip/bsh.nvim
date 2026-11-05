-- Remote files over any route. A file at the far end of a route (ssh, a
-- container, a container on an ssh host...) opens as a `bsh://<route>:<path>`
-- buffer: it is read with `cat` and written back with `cat >`, both run through
-- the route engine, so a transport only ever has to provide exec. No netrw/scp.
local M = {}

local job = require("bsh.job")
local qpath = require("bsh.util").qpath

local TIMEOUT = 30000

function M.bufname(route, path) return "bsh://" .. route .. ":" .. path end

-- `bsh://<route>:<path>` -> route, path (the route can't contain a colon; the path
-- can). `bsh://out/...` side buffers have no colon there, so they don't match.
function M.parse(name)
  local route, path = name:match("^bsh://([^:]+):(.+)$")
  return route, path
end

-- Run `cmd` at the far end of `route`, feeding it `stdin`. Returns the result of
-- vim.system():wait() (code, stdout, stderr).
local function exec(route, cmd, stdin)
  local ok, res = pcall(function()
    return vim.system(job.build_argv(route, cmd), { stdin = stdin, text = true }):wait(TIMEOUT)
  end)
  if not ok then return { code = -1, stdout = "", stderr = tostring(res) } end
  return res
end

-- BufReadCmd: fill the buffer with the remote file. A missing file is a new,
-- empty buffer (writing creates it); any other failure is reported.
function M.read(buf)
  local route, path = M.parse(vim.api.nvim_buf_get_name(buf))
  if not route then return end
  local res = exec(route, "if [ -e " .. qpath(path) .. " ]; then cat -- " .. qpath(path)
    .. "; else exit 44; fi")
  local text = res.stdout or ""
  local lines = vim.split(text, "\n", { plain = true })
  local eol = text:sub(-1) == "\n"
  if eol then table.remove(lines) end
  if res.code == 44 then
    lines = {}
    vim.notify("bsh: new file " .. route .. ":" .. path)
  elseif res.code ~= 0 then
    vim.notify("bsh: can't read " .. route .. ":" .. path .. ": " .. vim.trim(res.stderr or ""),
      vim.log.levels.ERROR)
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].eol = eol or #lines == 0
  vim.bo[buf].fixeol = true
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modified = false
  local ft = vim.filetype.match({ filename = path, contents = lines })
  if ft then vim.bo[buf].filetype = ft end
end

-- BufWriteCmd: send the buffer through `cat >` at the far end.
function M.write(buf)
  local route, path = M.parse(vim.api.nvim_buf_get_name(buf))
  if not route then return end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local text = table.concat(lines, "\n")
  if #lines > 0 and (vim.bo[buf].eol or vim.bo[buf].fixeol) then text = text .. "\n" end
  local res = exec(route, "cat > " .. qpath(path), text)
  if res.code ~= 0 then
    vim.notify("bsh: can't write " .. route .. ":" .. path .. ": " .. vim.trim(res.stderr or ""),
      vim.log.levels.ERROR)
    return
  end
  vim.bo[buf].modified = false
  vim.notify(('bsh: "%s:%s" %dL written'):format(route, path, #lines))
end

-- Open `path` at the far end of `route` in the current window.
function M.open(route, path)
  vim.cmd("edit " .. vim.fn.fnameescape(M.bufname(route, path)))
end

function M.setup()
  local group = vim.api.nvim_create_augroup("bsh_remote", { clear = true })
  vim.api.nvim_create_autocmd("BufReadCmd", {
    group = group, pattern = "bsh://*:*",
    callback = function(args) M.read(args.buf) end,
  })
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = group, pattern = "bsh://*:*",
    callback = function(args) M.write(args.buf) end,
  })
end

return M
