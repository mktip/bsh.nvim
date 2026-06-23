# bsh.nvim

> HIGHLY EXPERIMENTAL, AI WRITTEN, YET TO BE REVIEWED
> and if you already viewing this file in neovim with bsh installed, call :Bsh!

**Buffer SHell**: a shell that lives in a Neovim buffer instead of a terminal.

In a neovim buffer, imagine if you type

% pwd # and you \<CR> here
```out
/home/mktips/pockt/bsh.nvim
```

and it runs!

Even if it was over an ssh host

mktips@simurgh-base% uname -s
```out
Linux
```

or with an extremely long output

% cat /proc/cpuinfo # \<CTRL>+\<CR> to redirect and open the output in a scratch buffer
```log
bsh://out/README.bsh.md/1  ·  447 lines  ·  exit 0  ·  <CR> open
```

% for i in {a..z}; do echo $i; sleep 1; done
```out
a
b
c
d
e # can't really wait.. that's.. 26 seconds of my life # yes, <CTRL>+c works (kind of)
[exit 143]
[cancelled]
```

If you want a persistent session

%% cd /tmp
```out
(no output)
```

% pwd
```out
/home/mktips/pockt/bsh.nvim
```

%% pwd
```out
/tmp
```

---

You can also explore files (yes remote ones too)

: ~/pockt/bsh.nvim
```dir
../
bin/
deps/
docs/
examples/
lua/            # Navigable with <CR>!
plugin/
tests/
typst/
LICENSE
Makefile
README.bsh.md
```

mktips@simurgh-base: ~/.config/nvim
```dir
../
lua/
spell/
init.lua
```

: ~/pockt/bsh.nvim/examples/ -T
```tree
/home/mktips/pockt/bsh.nvim/examples//
├── bsh-home/
│   ├── db/
│   │   └── data/
│   │       ├── hosts.ndb
│   │       └── systems.ndb
│   ├── demo/
│   │   ├── conn.sh*            # Also navigable with <CR>
│   │   ├── greet/
│   │   ├── hello.sh*
│   │   └── menu.sh*
│   ├── docker/
│   │   ├── conn.sh*
│   │   ├── create.sh*
│   │   └── list.sh*
│   ├── host/
│   └── llm/
│       └── tools/
│           ├── reverse.py*
│           └── weather.py*
└── playground.bsh

10 directories, 11 files
```

> Technically there is also means of creating file in that mode, but it is a
> pure side effect for the time being. Planning to change it into a proper
> structured output later on (instead of relying on the `tree` command and
> adhoc parsing.)

---

```python %
# you can't see it, but above, the codeblock starts with \`\`\`python %
print("Works")
```
```out
Works
```

```python mktips@simurgh-base%
# this time \`\`\`python mktips@simurgh-base%
print("Across the oceans")
```
```out
Across the oceans
```

```python %%
# and here \`\`\`python %%
import os
```
```out
(no output)
```


```python %%
# likewise \`\`\`python %% (sharing the same python session/env)
os.system("cowsay persistantly")
```
```out
 ______________
< persistantly > and it is all within an editable buffer
 --------------
        \   ^__^
         \  (oo)\_______
            (__)\       )\/\
                ||----w |
                ||     ||
```


>> Hey, AI man, what animal is that? # (">>" to invoke an llm call with the prior cell as input)
```agent
That is an ASCII art **cow**!
```


demo.reverse !sdnammoc motsuc gniniatnoc seunem nwo ruoy enifed neve nac uoy
```out
you can even define your own menues containing custom commands!
```

## Motive

I'm frustrated with how uneditable the regular shell interface is, and one must
rely on terminal creators to support any form of intractability with the shell
outputs (highlighting urls, reverse output search, scroll). What if my shell,
was an nvim buffer, where i can search, edit, do all the nvim magic my heart
desires? I want to edit my terminal window however I like, and that's what this
project provides me. (although I do lose... interactive commands, shell
history, and... many other things, alas.. hopefully temporarily.. temporarily..)

(A secondary benefit is that I can share my shell sessions as markdown files (and
hopefully soon, nicely formatted typst documents (pdf, html (maybe), etc))

## Install


```lua
-- lazy.nvim
{ "mktip/bsh.nvim", config = true }   -- or just drop the repo on your runtimepath
```

`bsh` attaches automatically to `*.bsh/*.bsh.md` files. Turn any buffer into a shell on
demand with `:Bsh!`; `:Bsh` opens a fresh scratch one.

> Optional prerequisites (i think, i didn't review it):
> [otter.nvim](https://github.com/jmbuhr/otter.nvim) (for lsp in codeblocks),
> [conform.nvim](https://github.com/stevearc/conform.nvim) (for formatting in codebooks),
> [llm](https://github.com/simonw/llm) (for LLM integration, but any other harness with a print/headless mode should work)

## In the pipeline

- [ ] Adding ruby support (and a more generic way of supporting different language drivers)
- [ ] Adding container/jails shell support (even across the seas) and means of adding different transports
- [ ] Just as the markdown-ish support, hopefully <filename>.bsh.typ will be supported too
- [ ] A better way to define and interact with menus/commands. (currently relying on unused return values to communicate certain needs)
- [ ] Reviewing it like a human being (but man is short on free time)

## Credits

[Xiki (seems dead)](https://youtu.be/bUR_eUVcABg), [Plan9](https://en.wikipedia.org/wiki/Plan_9_from_Bell_Labs), [Emacs nerds](somewhere)

## License

[AGPL-3.0](LICENSE).
