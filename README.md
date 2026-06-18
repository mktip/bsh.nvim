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
% uname -s                 ← press <CR> on this line
```out                       ← bsh writes (and rewrites) this fence
Linux
```
```

The run marker is configurable — one variable, `require('bsh').config.marker`
(default `%`, doubled `%%` for a session). Set it back to `$` for the classic
look; the docs below use `%`.

## Cells

Marker grammar: a trailing **`%`** runs once, **`%%`** runs in a persistent
session, no marker is inert (so plain code blocks stay dead).

| Cell | What it does |
|------|--------------|
| `% cmd` | one-shot shell command → `out` fence |
| `%% cmd` | persistent shell — `export`/`cd`/venv carry across cells |
| `user@host% cmd` | run over `ssh` (one-shot or `%%` session) |
| `docker@id% cmd` | run inside a container (any transport — see below) |
| `docker@id%% cmd` | a *persistent* shell inside it — `%%` composes over any route |
| ` ```%% … ``` ` | multiline block, `<CR>` anywhere inside runs it all |
| ` ```python % ` / ` ```python %% ` | Python, one-shot or a stateful session |
| `: path` | navigable directory listing (`<CR>` drills in / opens files) |
| `: goto query` | fuzzy-jump to a directory, then list it |
| `https://…` | open the URL in your browser |
| `name.space` | run a command from your `$BSH_HOME` tree (see below) |
| `> instruction` | ask the `llm` CLI; `>>`/`>>>` fold in preceding cells as context |

Output streams live. Each result fence folds to a one-line summary.

### LSP inside `python` fences (optional, via otter.nvim)

Install [otter.nvim](https://github.com/jmbuhr/otter.nvim) and bsh wires it up
automatically: completion, hover, go-to-definition and diagnostics work *inside*
` ```python ` fences, served by your normal Python LSP (pyright/ruff/…). otter
mirrors each fence into a hidden buffer and attaches the language server there;
completion arrives through the standard `nvim_lsp` completion source.

It's a soft dependency — `config.otter` defaults to `"auto"` (on iff otter.nvim
is installed, a no-op otherwise; set `true` to force-on/warn, `false` to disable):

```lua
{ "mktip/bsh.nvim", dependencies = { "jmbuhr/otter.nvim" }, config = true }
```

For the dedicated `bsh` filetype, bsh points treesitter at the `markdown` parser
(so otter's injections query finds the fences, and the fenced code gets
highlighted); `*.bsh.md` buffers are already markdown and need nothing. Requires
the `markdown` (and your fence languages, e.g. `python`) treesitter parsers.

### Run keys: inline vs a side buffer

- **`<CR>`** runs the cell and shows output **inline**, in an owned fence below it.
- **`<C-CR>`** (or **`g<CR>`**) runs it but streams output into a **side buffer** —
  for long logs, `tail -f`, a dev server. The cell shows a compact `log`
  reference (`bsh://out/…`); `<CR>` on that line opens the buffer. The buffer is
  reused on re-run (no litter), and a cell that has a `log` fence stays routed
  there even on a plain `<CR>` — delete the fence to go back inline.

> **Terminal note:** many terminal emulators don't send `<C-CR>` distinctly from
> `<CR>` unless they speak the *kitty keyboard protocol* (kitty, foot, WezTerm,
> Ghostty, …). If `<C-CR>` does nothing special in your terminal, either enable
> that passthrough / "report all keys" in its config, or just use the always-works
> **`g<CR>`** fallback (or remap it: `vim.keymap.set("n", "<your-key>", …)`).

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

#### `bsh` — the same namespace from any shell

`bin/bsh` is the CLI half: it resolves a dotted name the same way (`bsh git.undo`
→ `$BSH_HOME/git/undo`, shebang-dispatched) and execs it **in the current
directory** — so a namespace command runs in *your* `$PWD`, not the document's.
Put it on `PATH` and it works in a `%`/`%%` cell, a real terminal, or over ssh:

```sh
export PATH="$PATH:/path/to/bsh.nvim/bin"
```

That's the answer to repo-relative commands: route through a session that's there.

```
%% cd ~/myrepo
%% bsh git.undo        # runs git.undo IN ~/myrepo (bsh never cd's)
```

(Inside the editor a bare `foo.bar` cell already resolves in-process; `bsh` is for
*shells* — sessions, terminals, remotes — where there's no plugin to ask.)

### Targets are routes (ssh, containers, jails, VMs — composable)

The bit before `%`/`:` is a **route**: `scheme@addr` hops chained with `/`, read
left = outermost (outside-in, big → small). The same route drives both verbs —
`:` lists, `%` runs:

```
docker@api % ps aux            # exec inside a local container
docker@api : /var/log          # …list a dir inside it
docker@api %% cd /srv          # a PERSISTENT shell inside it (env/cwd carry)
web@prod/docker@api % ps aux   # ssh to `prod`, then into container `api`
web@prod % uname -a            # plain ssh (unchanged)
```

`%%` sessions ride the *same* route, so a persistent shell works over any
transport, not just ssh. Each `%%` cell shows a small **cwd badge** at end of line
(`web@prod:/srv`) read from the shell's own `$PWD` — so it's right through `cd`,
dynamic paths, and subshells, where parsing the command never could be. Note it's
a *last-ran-here* marker, not a live prompt: it records where **that** cell ran,
so cells sharing one session can show different dirs until each is re-run (they
all share the shell's one current cwd — see `docs/design.md`).

The engine hardcodes only **ssh**; every other transport is a one-line entry in
`require('bsh').transports` — an argv template with `{addr}` and `{cmd}` holes (or
a `function(addr, inner)` for full control). So containers, FreeBSD jails, bhyve/
kvm guests are *your* definitions, not the plugin's:

```lua
require('bsh').transports.jail   = { "jexec", "{addr}", "sh", "-lc", "{cmd}" }
require('bsh').transports.podman = { "podman", "exec", "-i", "{addr}", "sh", "-lc", "{cmd}" }
require('bsh').transports.kube   = { "kubectl", "exec", "-i", "{addr}", "--", "sh", "-lc", "{cmd}" }
require('bsh').transports.vm     = { "ssh", "-T", "{addr}.vm.lan", "{cmd}" }  -- a guest you ssh to
-- docker ships as the worked example. Nesting (jail-in-VM, container-in-jail) just
-- composes: each hop wraps and escapes the one inside it.
```

A scheme is recognised iff it's a key in that table; anything else (`user@host`,
bare `host`) is a plain ssh destination, so existing cells are untouched.

**Drillable menus.** A namespace command can *declare* its output a self-feeding
menu by **exiting `150`** (bsh's `menu_exit`). bsh then renders it as a `` ```menu ``
fence — and **`<CR>` on any of its lines** appends that line, as one quoted
argument, to the trigger and re-runs it *in place*. So a `docker.list` that prints
container ids becomes navigable: `<CR>` an id → `docker.list <id>`, which the
script reinterprets ("drill into this one") and prints its actions, exiting `150`
again; `<CR>` an action drills further. A normal exit (`0`) is a terminal result
(plain `` ```out ``), not drillable. The trigger accumulates a breadcrumb
(`docker.list <id> start`) you can edit or backspace to walk back up.

Because the command *opts in* by its exit code, plain `<CR>` is safe — no special
gesture needed (`<C-CR>` keeps its only meaning, "send output to a side buffer").
A menu command is ~6 lines of shell — see `examples/bsh-home/demo/menu.sh`:

```sh
case $# in
  0) echo alpha; echo beta; exit 150 ;;                 # a menu
  1) echo "$1 selected"; echo start; echo stop; exit 150 ;;
  *) echo "$2 -> $1" ;;                                 # exit 0: a result
esac
```

**Emit a cell (exit `151`).** A command can also hand back a *new cell* instead of
output: print one line and **exit `151`** (`cell_exit`), and bsh replaces the
trigger (and its fence) with that line, cursor parked at its end. Combined with
menus this gives "pick X → get a cell for X": a `docker.conn` lists running
containers (a menu), and `<CR>` on one emits a `` docker@<id>%% `` **session cell**
— a live shell inside that container, ready to type into. The bundled
`examples/bsh-home/docker/` shows the trio:

| Command | Does |
|---------|------|
| `docker.conn` | menu of running containers → `<CR>` opens a `docker@<id>%%` shell |
| `docker.list` | menu of *all* containers → actions: `shell` / `start` / `stop` / `restart` / `rm` |
| `docker.create [name]` | spin up an alpine box (kept alive) → emits its `docker@<name>%%` shell |

**`db.*` — a faceted [ndb](https://9p.io/sys/doc/9.html) (Plan 9 database) browser.**
ndb is *schema-less* — an entry is just a bag of `attr=value` pairs, no two entries
need the same keys — so the browser is all menus and filters, never columns:

```
db                       → a menu of your .ndb files
db hosts                 → every entry, by its primary pair (sys=gate, sys=server, …)
db hosts sys=server      → that entry's fields, each a drillable facet
db hosts role=fileserver service=nfs   → AND-narrowed (the breadcrumb is a filter stack)
```

Every menu line is a valid `attr=value` term; `<CR>` appends it (AND) and re-runs,
backspace the breadcrumb to widen. And a resolved entry with a `dom`/`ip` offers a
`connect: <addr>` line — `<CR>` on it **emits a `<addr>%%` session cell** (a live
shell on that host), so the database connects you to what it describes:

```
db systems sys=simurgh-base
  → … dom=simurgh-base  user=mktips  …  connect: mktips@simurgh-base
                                          └ <CR> ⇒ mktips@simurgh-base%%  (a shell there)
```

Matching uses the real ndb engine (`ndbquery`), so install
[plan9port](https://github.com/9fans/plan9port) and put its `ndbquery` on `PATH`.
Point `$BSH_NDB` at your ndb tree (defaults to the demo data beside the command).
See `examples/bsh-home/db/`.

## Install

Requires Neovim 0.9+. Python cells need `python3`; agent cells need
[`llm`](https://llm.datasette.com/).

```lua
-- lazy.nvim
{ "mktip/bsh.nvim", config = true }   -- or just drop the repo on your runtimepath
```

`bsh` attaches automatically to `*.bsh` files. Turn any buffer into a shell on
demand with `:Bsh!`; `:Bsh` opens a fresh scratch one.

## Development

Tests use [mini.test](https://github.com/echasnovski/mini.nvim) (child-Neovim,
buffer-state assertions). `make test` fetches mini.nvim into `deps/` on first run
and executes the suite headless:

```sh
make test
```

Specs live in `tests/` (`test_*.lua`); `tests/helpers.lua` wraps the
"set up a lab buffer, run a cell, read it back" dance.

## Status

Built and in daily use; the roadmap leans toward **typesetting** a session —
Typst code blocks → beautiful PDF/HTML, so a coding session or runbook becomes a
report worth reading. See [`docs/design.md`](docs/design.md).

## License

[AGPL-3.0](LICENSE).
