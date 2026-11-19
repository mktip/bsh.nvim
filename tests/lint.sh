#!/bin/sh
# Type-check / lint lua/ and plugin/ with lua-language-server (settings in
# .luarc.json; tests/ is left out). Prints the problems; fails on any warning.
cd "$(dirname "$0")/.." || exit 1
VIMRUNTIME=$(nvim --clean --headless -c 'lua io.write(vim.env.VIMRUNTIME)' +q 2>&1)
export VIMRUNTIME
logs=$(mktemp -d)
report=$(lua-language-server --check . --checklevel=Warning --logpath "$logs" 2>&1 |
  sed 's/\x1b\[[0-9;]*m//g' | tr '\r' '\n' | grep -E '\[(Warning|Error)\]|problems found')
echo "$report"
echo "$report" | grep -q 'no problems found'
