-- ANSI escapes in command output: the text that lands in the buffer is always
-- clean (so a saved file never holds escape codes), and colours / bold /
-- underline are shown as highlights over it (config.ansi = "color"), or just
-- dropped ("strip"). Cursor movement, screen clears, OSC sequences (hyperlinks,
-- window titles) and other control codes are removed either way.
local M = {}

-- control characters other than tab (ESC included): what parse has to look at
local CTRL = "[\1-\8\11-\31]"

-- xterm's defaults for colours 0-15 (overridden by g:terminal_color_N when a
-- colorscheme sets them, so output matches your terminal theme)
local BASE16 = {
  "#000000", "#cd0000", "#00cd00", "#cdcd00", "#0000ee", "#cd00cd", "#00cdcd", "#e5e5e5",
  "#7f7f7f", "#ff0000", "#00ff00", "#ffff00", "#5c5cff", "#ff00ff", "#00ffff", "#ffffff",
}

local function hex256(n)
  if n < 16 then return vim.g["terminal_color_" .. n] or BASE16[n + 1] end
  if n >= 232 then
    local v = 8 + (n - 232) * 10
    return string.format("#%02x%02x%02x", v, v, v)
  end
  n = n - 16
  local function c(x) return x == 0 and 0 or 55 + x * 40 end
  return string.format("#%02x%02x%02x", c(math.floor(n / 36)), c(math.floor(n / 6) % 6), c(n % 6))
end

-- A colour is a 256-palette index (number) or a "#rrggbb" string (truecolor).
local function apply_sgr(st, params)
  local p = {}
  for x in ((params == "" and "0" or params) .. ";"):gmatch("([^;:]*)[;:]") do p[#p + 1] = tonumber(x) or 0 end
  local i = 1
  while i <= #p do
    local c = p[i]
    if c == 0 then
      for k in pairs(st) do st[k] = nil end
    elseif c == 1 then st.bold = true
    elseif c == 2 then st.dim = true
    elseif c == 3 then st.italic = true
    elseif c == 4 then st.underline = true
    elseif c == 7 then st.reverse = true
    elseif c == 9 then st.strikethrough = true
    elseif c == 22 then st.bold, st.dim = nil, nil
    elseif c == 23 then st.italic = nil
    elseif c == 24 then st.underline = nil
    elseif c == 27 then st.reverse = nil
    elseif c == 29 then st.strikethrough = nil
    elseif c >= 30 and c <= 37 then st.fg = c - 30
    elseif c >= 90 and c <= 97 then st.fg = c - 90 + 8
    elseif c >= 40 and c <= 47 then st.bg = c - 40
    elseif c >= 100 and c <= 107 then st.bg = c - 100 + 8
    elseif c == 39 then st.fg = nil
    elseif c == 49 then st.bg = nil
    elseif (c == 38 or c == 48) and p[i + 1] == 5 then
      st[c == 38 and "fg" or "bg"] = p[i + 2] or 0
      i = i + 2
    elseif (c == 38 or c == 48) and p[i + 1] == 2 then
      st[c == 38 and "fg" or "bg"] = string.format("#%02x%02x%02x", p[i + 2] or 0, p[i + 3] or 0, p[i + 4] or 0)
      i = i + 4
    end
    i = i + 1
  end
end

local ATTRS = { "bold", "dim", "italic", "underline", "reverse", "strikethrough" }

local function key(st)
  local k = { tostring(st.fg or ""), tostring(st.bg or "") }
  for _, a in ipairs(ATTRS) do k[#k + 1] = st[a] and a:sub(1, 2) or "" end
  return table.concat(k, "_")
end

-- Highlight groups are made on demand, one per distinct style, and re-made after
-- a :colorscheme (which clears them).
local groups = {} -- [name] = spec
local function define(name, spec) vim.api.nvim_set_hl(0, name, spec) end

local function group(st)
  if next(st) == nil then return nil end -- default style: no highlight
  local k = key(st)
  local name = "BshAnsi_" .. k:gsub("#", "x")
  if not groups[name] then
    local spec = {}
    local function col(v, which)
      if type(v) == "number" then
        spec[which] = hex256(v); spec["cterm" .. which] = v
      elseif type(v) == "string" then
        spec[which] = v
      end
    end
    col(st.fg, "fg")
    col(st.bg, "bg")
    for _, a in ipairs(ATTRS) do if st[a] and a ~= "dim" then spec[a] = true end end
    spec.cterm = {}
    for _, a in ipairs(ATTRS) do if st[a] and a ~= "dim" then spec.cterm[a] = true end end
    groups[name] = spec
    define(name, spec)
  end
  return name
end

vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("bsh_ansi", { clear = true }),
  callback = function()
    for name, spec in pairs(groups) do define(name, spec) end
  end,
})

-- Parse one line: returns the clean text and its highlight spans
-- { { start_col, end_col, group } ... } (byte columns into the clean text).
-- `st` (optional) carries SGR state across lines; a style left on at the end of
-- one line continues on the next, as in a terminal.
function M.parse(line, st)
  st = st or {}
  if not line:find(CTRL) then
    local g = group(st)
    return line, g and #line > 0 and { { 0, #line, g } } or {}
  end
  local out, spans = {}, {}
  local col, span_start, cur = 0, 0, group(st)
  local function flush()
    if cur and col > span_start then spans[#spans + 1] = { span_start, col, cur } end
    span_start = col
  end
  local i, n = 1, #line
  while i <= n do
    local b = line:byte(i)
    if b == 27 then
      local nxt = line:sub(i + 1, i + 1)
      if nxt == "[" then -- CSI: params, then a final byte in @..~
        local j = i + 2
        while j <= n and not line:sub(j, j):match("[@-~]") do j = j + 1 end
        if line:sub(j, j) == "m" then
          flush()
          apply_sgr(st, line:sub(i + 2, j - 1))
          cur = group(st)
        end
        i = j + 1
      elseif nxt == "]" then -- OSC: up to BEL or ESC \
        local j = i + 2
        while j <= n do
          local c = line:byte(j)
          if c == 7 then break end
          if c == 27 and line:sub(j + 1, j + 1) == "\\" then j = j + 1; break end
          j = j + 1
        end
        i = j + 1
      elseif nxt:match("[%(%)%*%+]") then -- charset designation: ESC ( B
        i = i + 3
      else
        i = i + 2
      end
    elseif b < 32 and b ~= 9 then -- other control characters (BEL, BS...)
      i = i + 1
    else
      local j = line:find(CTRL, i) or (n + 1)
      out[#out + 1] = line:sub(i, j - 1)
      col = col + (j - i)
      i = j
    end
  end
  flush()
  return table.concat(out), spans
end

local ns = vim.api.nvim_create_namespace("bsh_ansi")
M.ns = ns

-- Clean `lines` for the buffer. Returns the clean lines and a function that,
-- given the buffer and the row the first line went to (and the indent added
-- before each), puts the highlights on.
function M.prepare(lines)
  local mode = require("bsh.config").ansi
  if mode == false then
    return lines, function() end
  end
  local clean, all, st = {}, {}, {}
  for i, l in ipairs(lines) do
    local text, spans = M.parse(l, st)
    clean[i] = text
    all[i] = spans
  end
  if mode ~= "color" then return clean, function() end end
  return clean, function(buf, row, indent_len)
    vim.api.nvim_buf_clear_namespace(buf, ns, row, row + #clean)
    for i, spans in ipairs(all) do
      for _, s in ipairs(spans) do
        pcall(vim.api.nvim_buf_set_extmark, buf, ns, row + i - 1, indent_len + s[1],
          { end_col = indent_len + s[2], hl_group = s[3], priority = 90 })
      end
    end
  end
end

return M
