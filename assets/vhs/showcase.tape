# bsh.nvim showcase tape — render from the repo root with:
#   vhs assets/vhs/showcase.tape
# Produces assets/vhs/bsh.gif. Cells are TYPED LIVE: type a line, <Esc>, <CR>
# runs it in place. Output is ordinary buffer text -- so we edit a cow in place.

Output assets/vhs/bsh.gif

Require nvim

Set Shell bash
# foot's 0xProto misrenders in VHS's headless-Chromium pipeline here (leading-
# digit CSS name -> proportional fallback), so we use JetBrainsMono Nerd Font.
Set FontFamily "JetBrainsMono Nerd Font"
Set FontSize 19
Set Width 1120
Set Height 780
Set Padding 24
Set Theme "Catppuccin Mocha"
Set TypingSpeed 60ms

# --- boot nvim with the recording-only config, off-camera ---
Hide
Type "nvim --clean -u assets/vhs/init.lua assets/vhs/demo.bsh"
Enter
Sleep 2s
Show
Sleep 1.2s

# per cell: Go (open a line at the bottom) -> type -> Esc -> Enter (run)

# 1. it's a shell: a command's output lands right below it, as text.
Type "Go"
Type "% pwd"
Escape
Sleep 400ms
Enter
Sleep 1.6s

# 2. run cowsay... then EDIT the cow's speech in place -- it's just buffer text.
Type "Go"
Type "% cowsay hello world"
Escape
Sleep 400ms
Enter
Sleep 2.2s
# jump to the speech in the bubble (from the top: match 1 = the command line,
# match 2 = the bubble) and retype it -- proof the output is just editable text.
Type "gg"
Type "/hello world"
Enter
Type "n"
Sleep 600ms
Type "c2e"
Type "and it's all within an editable buffer!"
Escape
Sleep 2.5s

# 3. ask an LLM about the cell above with >> (it reads the previous cell: the cow)
Type "Go"
Type ">> Hey, AI man, what animal is that?"
Escape
Sleep 400ms
Enter
Sleep 16s

# 4. a %% cell keeps a persistent session; a plain % is one-shot.
Type "Go"
Type "# %% keeps a session across cells; % is one-shot:"
Escape
Type "Go"
Type "%% cd /tmp"
Escape
Sleep 300ms
Enter
Sleep 1s
Type "Go"
Type "% pwd"
Escape
Sleep 300ms
Enter
Sleep 1.2s
Type "Go"
Type "%% pwd"
Escape
Sleep 300ms
Enter
Sleep 1.8s

# 5. call your own scripts by dotted name (this one reverses its args).
Type "Go"
Type "# your own scripts, by dotted name:"
Escape
Type "Go"
Type "demo.reverse eman yb desserdda ,stpircs nwo ruoy nur"
Escape
Sleep 300ms
Enter
Sleep 2.2s

# 6. explore files right in the buffer as a foldable tree; expand nodes with <CR>.
Type "Go"
Type "# explore files as a foldable tree:"
Escape
Type "Go"
Type ": ../../examples -T"
Escape
Sleep 300ms
Enter
Sleep 2s
Type "/bsh-home"
Enter
Enter
Sleep 1.6s
Type "/demo/"
Enter
Enter

# rest on the expanded tree
Sleep 3.5s
