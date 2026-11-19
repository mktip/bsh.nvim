# bsh.nvim

**Buffer SHell**: a shell that lives in a Neovim buffer instead of a terminal.

![bsh.nvim demo](assets/vhs/bsh.gif)

Write `% command` on a line and press `<CR>`. bsh runs it and puts the output in
an `out` fence right below. Run it again and that fence is replaced, not
duplicated. The whole session is an ordinary buffer: search it, fold it, edit
the output in place, and save it as a file you can share or re-run later.

> [!WARNING]
> Experimental. Most of this was written with AI assistance and hasn't had a
> careful human review yet. Expect rough edges, and don't point it at anything
> you can't afford to break.

## Quick start

```lua
-- lazy.nvim
{ "mktip/bsh.nvim", opts = {} }
```

Then open any `notes.bsh` or `notes.bsh.md` file (or run `:Bsh` for a scratch
buffer, `:Bsh!` to turn the current buffer into one), and type:

```
% uname -a
```

Put the cursor on it and press `<CR>`. For a guided tour, open
[`examples/playground.bsh`](examples/playground.bsh).

## Cells

A cell is a line (or a fenced block) that bsh knows how to run.

| Cell | What it does |
|------|--------------|
| `% cmd` | run once in a fresh shell, output in an `out` fence below |
| `%% cmd` | run in the buffer's persistent shell: `cd`, `export`, venvs carry over |
| `user@host% cmd` | the same over ssh (`user@host%% cmd` for a persistent remote shell) |
| `docker@id% cmd` | inside a container (any transport you define, see below) |
| ` ```%% ` … ` ``` ` | a multiline shell block; `<CR>` anywhere inside runs it |
| ` ```python % ` / ` ```python %% ` | Python, one-shot or a persistent interpreter (remote too: ` ```python user@host%% `) |
| ` ```node %% `, ` ```sqlite %% `… | any language you add (see [More languages](#more-languages)) |
| `: path` | list a directory; `<CR>` on an entry drills in or opens the file |
| `: path -T` / `-H` | a foldable tree / include dotfiles |
| `: goto query` | fuzzy-jump to a directory under `$HOME` (needs `fd` + `fzf`), then list it |
| `user@host: path` | the same, on a remote machine |
| `> question` | ask an AI agent, no memory (see [Agent cells](#agent-cells)) |
| `>> question` | ask in this file's ongoing conversation |
| `https://…` | open the URL in your browser |
| `name.space` | run a script from your `$BSH_HOME` (see [Your own commands](#your-own-commands)) |

Lines that aren't cells are just text: write notes between them. Output streams
in live, and every result fence folds to a one-line summary (`za`).

**The buffer is your history.** To run something again, scroll up (or `[c`),
edit the cell and press `<CR>`: its old result is replaced in place. Output is
ordinary text you can edit too, but a re-run overwrites it. Inline output stops
after 2000 lines (`output_max_lines`); use `g<CR>` for anything bigger.
While a cell runs, a dim `running 4s…` sits at the end of its line, then
`1.3s · ok` or `0.2s · exit 1` (not saved into the file; `status = false` hides
it). Colour codes in output are shown as highlights and kept out of the text, so a
saved file stays clean (`ansi = "strip"` drops the colours, `false` keeps the
raw codes).

## Keys

| Key | Action |
|-----|--------|
| `<CR>` | run the cell under the cursor (output inline) |
| `g<CR>` / `<C-CR>` | run it, sending output to a side buffer (for long logs, `tail -f`, servers); the cell keeps a `log` link, `<CR>` on it opens the buffer |
| `<C-c>` | cancel the running cell (a session cell is interrupted; the session survives) |
| `<C-k>` | reset the session under the cursor (fresh shell / interpreter) |
| `<localleader>r` | replay a session from the top down to the cursor, in a fresh interpreter |
| `<localleader>t` | hide / show the agent's thinking lines |
| visual `<CR>` | when the selection ends on a `>` cell, ask it with the selected lines attached |
| `<M-CR>` (Alt+Enter) | insert mode: run the cell, then start the next one (same `%`, `user@host%%`, `>>` prefix) a blank line below its output. Normal mode: just open that new prompt, without running anything (on prose, a bare `% `) |
| `<Tab>` / `<C-x><C-o>` | complete a command or path from wherever the cell runs (see [Completion](#completion)) |
| `<C-p>` / `<C-n>` | on a prompt, in insert mode: older / newer commands from that route's history, starting with what you've typed (see [History](#history)) |
| `<localleader>h` | that route's history as a buffer (`:BshHistory`) |
| `]c` / `[c` | jump to the next / previous cell |
| `io` / `ao` | text objects for a cell's output (body / whole fence): `yio` copies it, even when folded; `dao` deletes it |

Commands: `:Bsh[!]`, `:BshCancel`, `:BshReset[!]` (`!` = every session in the
buffer), `:BshReplay`, `:BshHistory`, `:BshThinking`, `:BshForget`. See `:h bsh` for details.

> `<C-CR>` only reaches Neovim in terminals that speak the kitty keyboard
> protocol (kitty, foot, WezTerm, Ghostty...). `g<CR>` always works.

## Completion

In a shell cell, completion comes from wherever that cell runs:
`me@server% sq<Tab>` offers the server's `squeue`, `docker@api% ls /e<Tab>`
the container's `/etc/`. Words in command position complete as commands
(bash's `compgen -c` on that machine, or a `$PATH` scan if it has no bash);
anything else completes as a path. Relative paths are resolved in the cell's
directory: the file's folder locally, `$HOME` remotely, and for a `%%`
session the directory its shell is in right now.

Nothing pops up while you type. You ask for it with `<C-x><C-o>`. If you use
nvim-cmp, a `bsh` source is added to bsh buffers, so your own trigger works
(with `autocomplete = false`, that's the key you mapped). Without nvim-cmp,
`<Tab>` on a shell line completes. A route's command list is cached for 5
minutes, directory listings for 5 seconds. Remote lookups cost one ssh round
trip, so set up `ControlMaster` (below). `complete = false` turns all of this
off.

## More languages

Besides the shell and Python, any interpreter that reads code on stdin can be a
cell language, once (` ```lang % `) or as a persistent process (` ```lang %% `),
locally or along a route (` ```sqlite me@server%% `):

```lua
require("bsh").setup({
  languages = {
    sqlite = { cmd = "sqlite3 -batch app.db", print = ".print %s" },
    node = { cmd = "node", print = 'console.log("%s")',
      session = [[node -e "require('repl').start({ prompt: '', ignoreUndefined: true })"]] },
    lua = { cmd = "lua -", session = "lua -i", print = 'print("%s")', prompt = "> ", echo = true },
  },
})
```

- `cmd` runs a one-shot with the block on its stdin; `session` (if different)
  starts the persistent process.
- `print` is a statement in that language that prints its argument, with `%s`
  where bsh puts a marker. After each block bsh sends it, and everything printed
  before the marker is that cell's output.
- For a REPL that's chatty, `prompt` is removed from output lines and `echo =
  true` drops the input lines it echoes back. Its startup banner is skipped.
- A session can't report an exit code, so its cells always end `ok`, and
  `<C-c>` can't interrupt it (`<C-k>` resets it).

## History

Each route has its own history: what you ran through bsh there, from any
file, followed by that machine's own shell history (`~/.bash_history`, zsh's
or fish's, read once per session over the route). So on a server you also get
what you typed there in an ordinary terminal. Route aliases share a history
with the route they stand for.

On a prompt, `<C-p>` steps back through the commands that start with what
you've typed (zsh's prefix search): type `sq`, press `<C-p>`, get
`squeue -u me`. `<C-n>` goes forward; going past the newest gives back what
you typed. A dim `2/5` at the end of the line shows where you are. `<Up>`
stays a cursor motion, since this is still a buffer.

To search it, `:BshHistory` (or `<localleader>h`) opens the route's history
as a buffer, newest at the bottom. Use `/`, a fuzzy finder, anything; `<CR>`
on a line puts it in the prompt you came from (or a new one below the cell).

History lives in `stdpath("state")/bsh/history`, one file per route.
`history_shell = false` skips the machine's own history; `history = false`
turns it all off.

## Remote machines and containers

The part before the marker is a **route**. A bare `host` or `user@host` is ssh
(your `~/.ssh/config` aliases work). Anything else is a `scheme@addr` hop whose
scheme you define, and hops chain with `/`:

```
me@server% uname -a              # ssh
docker@api% ps aux               # docker exec (podman@api for podman)
docker@api%% cd /srv             # a persistent shell inside the container
me@server/docker@api% ps aux     # ssh to server, then into its container
me@server: /var/log              # list a remote directory
```

Long routes get an alias:

```lua
require("bsh").setup({ routes = { box = "me@server", api = "box/podman@api" } })
```

Then `api%% ps` runs in that container, and `box/docker@db% ls` works too.

**Make remote cells fast.** Each `%` opens a new ssh connection. Let ssh reuse
one, and remote cells feel local:

```
# ~/.ssh/config
Host *
  ControlMaster auto
  ControlPath ~/.ssh/cm-%r@%h:%p
  ControlPersist 10m
```

`<CR>` on a file in a remote listing opens it as a `bsh://<route>:<path>`
buffer, read and written (`:w`) over the same route. So you can edit a config
file inside a container on another machine just like a local one.

ssh, `docker@` and `podman@` work out of the box. Add your own as argv
templates with `{addr}` and `{cmd}` holes:

```lua
require("bsh").setup({
  transports = {
    jail   = { "jexec", "{addr}", "sh", "-lc", "{cmd}" },
    kube   = { "kubectl", "exec", "-i", "{addr}", "--", "sh", "-lc", "{cmd}" },
  },
})
```

## Agent cells

`> question` runs a headless agent and writes its reply into an `agent` fence.
It uses [pi](https://pi.dev) when it's installed, otherwise the
[`llm`](https://llm.datasette.com/) CLI.

What it sees comes straight from the buffer, as it is now (unsaved edits
included), pasted into the prompt:

```
% tar -xf backup.tar.zst -C /root
```out
tar: backup.tar.zst: Cannot open: No such file or directory
```
> why did it fail?                     <- sees the cell just above
>> what should I run instead?          <- sees everything since that `>`
```

| You write | The agent gets |
|-----------|----------------|
| `> q` | q, plus the cell just above (a command and its output, prose in between), but not an agent cell, and not past a heading or `---`. So a new `>` is a fresh conversation. |
| `>> q` | everything from the last `>` down: the cell it saw, the questions and answers, commands you ran in between. With no `>` above, same as `>`. |
| visual selection, `<CR>` on a `>` | exactly the selected lines, plus q |

A dim note after the question shows what was sent (`1 cell · 165 chars`,
`thread: 3 cells · 2.1k chars`, `fresh`). There's no hidden memory by default:
what's above the question is all it knows. `agent_memory = "session"` makes pi
also remember a file's earlier turns until you quit Neovim (`"file"`: across
restarts; `:BshForget` starts over).

- The agent is read-only by default: it can read and search files itself, and
  for anything else it suggests a command for you to run. End the arrows with
  `!` (`>!`, `>>!`) to let it run commands and edit files.
- Tool calls show up as `[tool] arg` lines and thinking as `| ` lines (hide them
  with `<localleader>t`).
- `[model]> question` picks a model (pi) or template (llm). With
  `agent_memory` on, a pi conversation keeps the model it started with;
  `agent_model = "default"` makes every cell use pi's current default instead
  (or set a model name).

The agent isn't wired into bsh's core. It's a cell kind written with the same
rule API as your own (below), in
[`lua/bsh/contrib/agent.lua`](lua/bsh/contrib/agent.lua), so it's also the
example to copy. `agent = false` turns it off, and a rule of your own matching
`>` takes over.

## Your own commands

Point `$BSH_HOME` at a directory (default `~/.config/bsh`) and its tree becomes a
dotted command namespace: `git.undo` runs `$BSH_HOME/git/undo`. Any executable
works; it's run by its shebang, so the extension doesn't matter.

```
demo.weather Ankara | tr a-z A-Z    # args, pipes and redirects work
demo.                               # list a folder as a navigable menu
demo.weather!                       # open its source (or scaffold a new command)
```

A command can talk back to bsh through its exit code:

- **exit 150**: its output is a **menu**. `<CR>` on a line re-runs the command
  with that line appended as an argument, so a script can be drilled into.
- **exit 151**: its first line is a **new cell** that replaces the trigger, e.g.
  a container picker that hands you a `docker@<id>%% ` shell.

[`examples/bsh-home`](examples/bsh-home) has small examples of each, plus two
pickers: `ssh` lists the hosts from your ssh config and history, and
`containers` lists running podman/docker containers, here or on a host
(`containers me@server`). `<CR>` on an entry gives you a `%%` session cell in it. Try them with
`export BSH_HOME=/path/to/bsh.nvim/examples/bsh-home`.

`bin/bsh` resolves the same names from any shell (`bsh git.undo`), running in
*your* current directory. Put it on your `PATH` to use your commands in `%%`
sessions, a normal terminal or over ssh.

## Your own cell kinds

Every line is matched against an ordered list of rules, first match wins (think
Plan 9's plumber). Yours come first, then bundled ones like the `>` agent. A
rule is a Lua pattern plus a function that gets its captures. Return a shell
command to run it like a `%` cell, or handle the line yourself:

```lua
require("bsh").setup({
  rules = {
    -- `PROJ-123` on its own line opens the ticket
    { match = "^%s*(%u+%-%d+)%s*$", run = function(_, id)
        vim.ui.open("https://jira.example.com/browse/" .. id) end },
    -- `man ls` shows the page, output inline
    { match = "^man (%S+)$", run = function(_, page) return "man " .. page .. " | col -b" end },
  },
})
```

Return `false` to let the line fall through to the built-in rules.

A rule can go further and become a full cell kind, like the agent:

```lua
{
  -- `sql> select ...` runs against a database; the result gets its own fence
  match = "^sql> (.+)$",
  run = function(ctx, query)
    ctx.run({ "sqlite3", "-header", "app.db", query }, { placeholder = "...querying..." })
  end,
  tag = "rows",                                  -- its fence is a ```rows block
  prompt = function() return "sql> " end,        -- <M-CR> opens the next `sql> `
}
```

- `ctx.run(cmd, opts)` streams a command (an argv list, or a shell string run on
  `opts.route`) into the cell's fence, which is replaced on a re-run and
  selectable with `io`/`ao`. `<C-c>` cancels it. `opts.decode(raw)` turns raw
  output into text (for JSON event streams), and `opts.on_done(first, last)`
  runs when the output is complete.
- `ctx.selection` holds the lines above the cell when you run it from a visual
  selection. `ctx.buf`, `ctx.row`, `ctx.line`, `ctx.cwd` describe where it is.
- `match` can also be a function `(line) -> captures`.
- `fold = { test = fn(line), label = "…" }` folds runs of matching lines inside
  the fence on their own (the agent's thinking), and `attach = fn(buf)` adds
  keys or commands to bsh buffers.

## Install

Requires **Neovim 0.10+** and a POSIX shell. Everything else is optional:

| For | Install |
|-----|---------|
| Python cells | `python3` (`config.python` picks another) |
| Agent cells | [pi](https://pi.dev) or [`llm`](https://llm.datasette.com/) |
| `: goto` | [`fd`](https://github.com/sharkdp/fd) and [`fzf`](https://github.com/junegunn/fzf) |
| LSP inside ` ```python ` fences | [otter.nvim](https://github.com/jmbuhr/otter.nvim) (picked up automatically) |

Run `:checkhealth bsh` to see what's available.

With lazy.nvim, use the spec from [Quick start](#quick-start). With any other
plugin manager, add the repo to your runtimepath; the plugin sets itself up and
`setup()` is only needed to change options.

bsh attaches to `*.bsh` (its own filetype) and `*.bsh.md` / `*.bsh.markdown`
(which stay markdown, so they render nicely on GitHub).

## Configuration

Defaults shown; pass only what you want to change:

```lua
require("bsh").setup({
  marker = "%",             -- the run marker; "$" if you prefer
  remote_login = true,      -- remote cells run in a login shell (loads profile/bashrc)
  transports = {            -- besides ssh; yours are merged in
    docker = { "docker", "exec", "-i", "{addr}", "sh", "-lc", "{cmd}" },
    podman = { "podman", "exec", "-i", "{addr}", "sh", "-lc", "{cmd}" },
  },
  routes = {},              -- route aliases: { box = "me@server", api = "box/podman@api" }
  python = "python3",
  languages = {},           -- more cell languages, see "More languages"
  output_max_lines = 2000,  -- inline output cap (false = none); g<CR> has no cap
  agent = "auto",           -- "pi", "llm", "auto" (pi if installed), or false: no `>` cells
  agent_memory = false,     -- pi also remembers earlier turns: "session" (until you quit) or "file"
  agent_model = false,      -- false: pi decides; "default": pi's current default; or a name
  agent_tools = "read,grep,find,ls",                         -- pi, for `>`
  agent_tools_write = "read,grep,find,ls,bash,edit,write",   -- pi, for `>!`
  agent_thinking = false,   -- pi --thinking level: "low", "high", ...
  agent_show_thinking = true,
  agent_hide_thinking = false,  -- start with thinking folded away
  otter = "auto",           -- LSP in python fences when otter.nvim is installed
  ansi = "color",           -- colours in output as highlights; "strip", or false for raw codes
  status = true,            -- elapsed time / exit status at the end of a cell's line
  complete = true,          -- on-request completion from where the cell runs
  history = true,           -- per-route history: <C-p>/<C-n> on a prompt, :BshHistory
  history_shell = true,     -- ...including the machine's own shell history
  history_max = 5000,       -- entries kept per route
})
```

All options are documented in [`lua/bsh/config.lua`](lua/bsh/config.lua) and
`:h bsh-config`.

## Limitations

- No interactive programs: anything that needs a TTY (`vim`, `htop`, password
  prompts, `ssh` asking for a passphrase) won't work. Use key-based ssh auth.
- Completion covers commands and paths, not each command's own arguments
  (`git che…`).
- bsh reads a machine's shell history but doesn't write to it.

## Motive

I'm frustrated with how uneditable the regular shell interface is, and how one
must rely on terminal creators to support any form of interaction with shell
output (highlighting URLs, searching output, scrolling). What if my shell was a
Neovim buffer, where I can search, edit, and do all the Neovim magic my heart
desires? I want to edit my terminal window however I like, and that's what this
project gives me. (Although I do lose interactive commands, shell history, and
many other things. Hopefully temporarily.)

A side benefit: sessions are plain `.bsh.md` files, so I can share them as
markdown.

## Development

```sh
make test   # headless mini.test suite, files in parallel; fetches mini.nvim into deps/ first
make test FILES=tests/test_agent.lua   # just some files
make lint   # lua-language-server over lua/ and plugin/ (.luarc.json); CI runs both
```

The demo GIF is recorded with [VHS](https://github.com/charmbracelet/vhs):
`vhs assets/vhs/showcase.tape`.

## Roadmap

- More language drivers beyond Python (Ruby next), and a generic way to add them
- A cleaner protocol for menus and commands than exit codes
- A proper human review of the code

## Credits

Inspired by [Xiki](https://youtu.be/bUR_eUVcABg),
[Plan 9](https://en.wikipedia.org/wiki/Plan_9_from_Bell_Labs) and Emacs nerds
everywhere.

## License

[AGPL-3.0](LICENSE).
