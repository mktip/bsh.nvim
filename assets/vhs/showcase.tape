# bsh.nvim showcase tape. Render from the repo root with:
#   vhs assets/vhs/showcase.tape
# Produces assets/vhs/bsh.gif. Everything is TYPED LIVE into a fresh
# assets/vhs/demo.bsh.md: type a cell, <Esc>, <CR> runs it in place.
#
# The remote host ($DEMO_HOST, set in the hidden setup below) and the agent's
# model server are WARMED UP before recording starts, so the sleeps below only
# cover output appearing, not connection setup or model loading.
#
# Helpers used below:
#   Go            open a fresh line at the very bottom (where we keep typing)
#   2k then Enter run a just-typed ```fence``` (jump to its opener, then <CR>)

Output assets/vhs/bsh.gif

Require nvim
Require pi
Require cowsay

Set Shell bash
Set FontFamily "CaskaydiaCove Nerd Font Mono"
Set FontSize 18
Set Width 1180
Set Height 860
Set Padding 22
Set Theme "Catppuccin Mocha"
Set TypingSpeed 35ms
# 24fps keeps the final GIF encode from eating several GB of RAM
Set Framerate 24

Hide
# warm up: ssh connection, remote python, and one agent round-trip (keeps the
# model loaded and pi's startup cached), then start from an empty document
Type "ssh mktips@simurgh-base 'uname -s; python3 -c 1' >/dev/null; pi -p --no-session 'Reply: ok' >/dev/null 2>&1; rm -f assets/vhs/demo.bsh.md; clear"
Enter
Sleep 8s
Type "nvim --clean -u assets/vhs/init.lua assets/vhs/demo.bsh.md"
Enter
Sleep 1s
Show
Sleep 600ms

# 1. a local shell cell
Type "Go"
Type "% pwd"
Escape
Sleep 200ms
Enter
Sleep 1s

# 2. ...or on another machine, over ssh
Type "Go"
Type "mktips@simurgh-base% uname -sr"
Escape
Sleep 200ms
Enter
Sleep 1.5s

# 3. long output: g<CR> sends it to a scratch buffer, leaving a link behind
Type "Go"
Type "mktips@simurgh-base% cat /proc/cpuinfo"
Escape
Sleep 200ms
Type "g"
Enter
Sleep 1.5s

# 4. a slow loop, cancelled with <C-c>
Type "Go"
Type "% for i in {a..z}; do echo $i; sleep 0.5; done"
Escape
Sleep 200ms
Enter
Sleep 2.2s
Ctrl+C
Sleep 1s

# 5. % is one-shot, %% is a persistent session
Type "Go"
Type "%% cd /tmp"
Escape
Enter
Sleep 600ms
Type "Go"
Type "% pwd"
Escape
Enter
Sleep 700ms
Type "Go"
Type "%% pwd"
Escape
Enter
Sleep 1.2s

# 6. files: a local listing, a remote one, then a foldable tree
Type "Go"
Type ": ../.."
Escape
Enter
Sleep 1.2s
Type "Go"
Type "mktips@simurgh-base: ~/.config/nvim"
Escape
Enter
Sleep 1.5s
Type "Go"
Type ": ../../examples -T"
Escape
Enter
Sleep 900ms
Type "/bsh-home"
Enter
Enter
Sleep 800ms
Type "/demo/"
Enter
Enter
Sleep 1.2s

# 7. code fences: python here...
Type "Go"
Type "```python %"
Enter
Type 'print("Works")'
Enter
Type "```"
Escape
Type "2k"
Enter
Sleep 1s

# 8. ...and python over there
Type "Go"
Type "```python mktips@simurgh-base%"
Enter
Type 'print("Across the oceans")'
Enter
Type "```"
Escape
Type "2k"
Enter
Sleep 1.5s

# 9. a shared %% python session: import in one cell, use it in the next
Type "Go"
Type "```python %%"
Enter
Type "import os"
Enter
Type "```"
Escape
Type "2k"
Enter
Sleep 800ms
Type "Go"
Type "```python %%"
Enter
Type 'os.system("cowsay persistently")'
Enter
Type "```"
Escape
Type "2k"
Enter
Sleep 1.5s

# 10. output is just buffer text: edit the cow's line in place
Type "/< persistently"
Enter
Sleep 300ms
Type "A and it is all an editable buffer!"
Escape
Sleep 1.5s

# 11. ask the AI about it: select from the cow down to a `>>` cell, <CR> attaches
#     the selection; the next `>>` continues the same conversation
Type "Go"
Type ">> what animal is this? one short sentence"
Escape
Type "V?< persistently"
Enter
Sleep 400ms
Enter
Sleep 5s
Type "Go"
Type ">> what sound does it make? one word"
Escape
Enter
Sleep 4s

# 12. your own scripts, by dotted name
Type "Go"
Type "demo.reverse !sdnammoc nwo ruoy enifed nac uoy"
Escape
Enter
Sleep 1.2s

# rest on the finished session
Sleep 2.5s
