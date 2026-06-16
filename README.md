# bsh.nvim

**Buffer SHell** — a shell that lives in a Neovim buffer instead of a terminal.

A regular terminal is append-only: you can't go back and re-run a command in
place, edit its arguments, or keep a tidy record. `bsh` flips that. You write
commands as ordinary lines in a normal buffer, press `<CR>`, and the output
lands in a fenced block the plugin *owns* and rewrites — so re-running is
idempotent, the whole thing survives `:w`, and the buffer doubles as an
editable, replayable session log.

It's [Xiki](https://xiki.org/) in spirit — text as an executable interface,
prose and commands interleaved, expand-in-place instead of scrollback — but
built for Neovim and centred on being a *shell* first, a document second.

```
$ uname -s                 ← press <CR> on this line
```out                       ← bsh writes (and rewrites) this fence
Linux
```
```

## Cells

Marker grammar: a trailing **`$`** runs once, **`$$`** runs in a persistent
session, no marker is inert (so plain code blocks stay dead).

| Cell | What it does |
|------|--------------|
| `$ cmd` | one-shot shell command → `out` fence |
| `$$ cmd` | persistent shell — `export`/`cd`/venv carry across cells |
| `user@host$ cmd` | run over `ssh` (one-shot or `$$` session) |
| ` ```$$ … ``` ` | multiline block, `<CR>` anywhere inside runs it all |
| ` ```python $ ` / ` ```python $$ ` | Python, one-shot or a stateful session |
| `: path` | navigable directory listing (`<CR>` drills in / opens files) |
| `: goto query` | fuzzy-jump to a directory, then list it |
| `https://…` | open the URL in your browser |
| `name.space` | run a command from your `$BSH_HOME` tree (see below) |
| `> instruction` | ask the `llm` CLI; `>>`/`>>>` fold in preceding cells as context |

Output streams live. Each result fence folds to a one-line summary.

### `$BSH_HOME` — a command namespace

Point `$BSH_HOME` at a directory and its tree *is* a dotted command namespace,
1:1, no registry: `llm.tools.weather` → `$BSH_HOME/llm/tools/weather.py`. Leaves
are shebang'd executables (the extension is cosmetic); a folder with an `.enter`
script runs that, otherwise it lists. A dual-purpose Python leaf can be both the
thing `<CR>` runs *and* a tool registered for the `llm` CLI. See
[`examples/bsh-home/`](examples/bsh-home) and [`docs/design.md`](docs/design.md).

```sh
export BSH_HOME="$HOME/pockt/bsh"
```

## Install

Requires Neovim 0.9+. Python cells need `python3`; agent cells need
[`llm`](https://llm.datasette.com/).

```lua
-- lazy.nvim
{ "mktip/bsh.nvim", config = true }   -- or just drop the repo on your runtimepath
```

`bsh` attaches automatically to `*.bsh` files. Turn any buffer into a shell on
demand with `:Bsh!`; `:Bsh` opens a fresh scratch one.

## Status

Built and in daily use; the roadmap leans toward **typesetting** a session —
Typst code blocks → beautiful PDF/HTML, so a coding session or runbook becomes a
report worth reading. See [`docs/design.md`](docs/design.md).

## License

[AGPL-3.0](LICENSE).
