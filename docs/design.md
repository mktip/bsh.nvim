# bsh — design notes

Living design doc for `bsh.lua`. Captures the *direction* and the decisions
made while iterating, especially the parts not yet built. The plugin itself is
the source of truth for what already works; this file is for the model we're
building toward so it stops living only in chat.

## What bsh is (and the order of priorities)

A **live document buffer** where prose-syntax lines are runnable cells. A cell is
a trigger line plus a result fence the plugin *owns* and rewrites, so re-running
is idempotent and the whole thing survives `:w`, folds, and renders as plain
markdown.

The framing shifted as it got used, and the priority order now is:

1. **An editable shell, first.** The primary draw is fixing what terminals can't
   do: terminals are append-only, you can't go back three commands, fix a flag,
   and re-run *in place*; you can't fold output you don't care about; you can't
   keep an editable working set of commands. bsh inverts all of that — every
   command stays live, editable text.
2. **Convertible to a document, second.** A nice consequence of being plain text
   + markdown fences, but explicitly the B-side.

Corollary that drives everything below: **bsh must interact with the real
filesystem and OS.** It is not a document-only world. The document is a *lens*
onto the machine, never the owner of state.

Design lineage: this is Xiki's menu model (`path → handler/tree`, with the
ancestor path as context) and Simon Willison's `llm` tool model (`name →
callable`), recognized as the *same* abstraction — a **named capability** — and
kept filesystem-backed instead of in-memory.

## Already built (pointers, not spec)

Inline + fenced cells, all idempotent / async / streaming:

- `$ cmd` one-shot shell; `user@host$ cmd` remote (login shell over ssh).
- `$$ cmd` persistent **session** (shared env/cwd/vars), local or `user@host$$`
  remote; sessions are keyed per buffer by `(language, target)`.
- Multiline **input fences**: ` ```$ ` / ` ```$$ ` / ` ```python $ ` / ` ```python $$ `.
  Rule: a trailing `$` = run once, `$$` = shared session, no marker = inert.
  The language word stays first so the block syntax-highlights.
- `python` cells via a tiny **driver** (length-prefixed `exec` into a persistent
  globals dict) — NOT a bare REPL (which breaks on indented multiline).
- `: path` navigable listing; `-T` tree; `-H` hidden; drill-in. `: goto <query>`
  fuzzy-resolves via the user's own `here` script and lists the result.
- `https://…` opens in the browser; `>`/`>>`/`>>>` agent cells (`llm`) with
  N preceding cells of context; output in an owned ` ```agent ` fence
  (model-emitted ``` neutralised to a look-alike).
- Live **streaming** output; `M.attach()` / `:Bsh!` to lab-ify any buffer.

## The composability model (the thing this doc is really about)

The goal: user-defined, reusable commands that are **both** runnable by the human
(press Enter) **and** usable by the `>` agent (as an `llm` tool) — from a single
definition, living as real files on disk.

### 1. `$BSH_HOME` — a 1:1 namespace tree (no registration)

There is **no config registry** mapping names to locations. The directory
structure *is* the namespace. One env var:

```
$BSH_HOME              # default: ~/pockt/bsh  (so it syncs via pockt/Syncthing)
```

A dotted name maps one-to-one onto the tree:

```
llm.tools.weather   →   $BSH_HOME/llm/tools/weather.py
```

`llm` is not a location, it's just the top folder. This is essentially **`~/bin`
with namespacing** — convention over configuration, fully on-disk, syncable.

### 2. Enter dispatches on what's at the path

Three rules, graceful degradation:

- **file** → execute it.
- **directory with a `.enter`** → execute that (the folder's own behavior).
- **directory without one** → list it (pure navigation — the common case).

Most folders are plain navigable namespaces; a folder opts into custom behavior
by dropping one executable `.enter` inside it. Reserved name is `.enter`:
hidden, collision-proof, self-documenting. (`index` is the visible alternative
if we ever want it.)

### 3. Execution is shebang-driven, not extension-driven

bsh checks the executable bit and runs the file; the `#!/usr/bin/env python3`
(or `…bash`, `…ruby`) shebang picks the interpreter. **The extension is
cosmetic** — a hint for the human/editor, never read by bsh.

Consequences:
- No `.sh`-must-be-canonical rule, no `.py`-symlinks-to-`.sh` contortions.
- A node maps to exactly **one** executable. Two files for one node is a user
  error we warn on, not a resolution rule.

### 4. The leaf is one dual-purpose file (the keystone)

A leaf is a single file that is **both** an executable script (its Enter
behavior) **and** an importable plugin (its tool registration), forked by the
oldest idiom in Python:

```python
# $BSH_HOME/llm/tools/weather.py
def weather(city: str) -> str:
    "Get the weather for a city"
    ...

@llm.hookimpl                    # when `llm` imports it as a plugin
def register_tools(register):
    register(weather)

if __name__ == "__main__":       # when bsh runs it on Enter
    import sys
    print(weather(sys.argv[1] if len(sys.argv) > 1 else "Istanbul"))
```

- **Enter on `llm.tools.weather`** → `python weather.py` → the `__main__` block.
- **`llm` loads it / `-f` imports it** → `register_tools` hookimpl fires; `__main__`
  does not.

This is why Enter-behavior needs **no per-leaf configuration anywhere**: the file
*is* its behavior. The genericity falls out because the unit is "an executable,
importable file" and the language already gives you the fork. Python is the
primary tool language (that's where `llm`'s tool API lives); that's fine and even
simplifying, since a "tool cell" and a "python cell" are the same primitive.

### Why this satisfies the constraints

- **Filesystem/OS-native, not document-only:** the source of truth is files; the
  document is a viewport. `llm.tools` *is* the plugins directory under
  `$BSH_HOME/llm/tools/`, discovered by `llm` the normal way.
- **Generic:** `llm.tools` is just the first namespace. `bin.` → scripts,
  `notes.` → notes, etc. — same three rules, no new code per namespace.
- **One definition, two consumers:** the human runs it; the agent calls it.

## Deferred (layers on top, not now)

- **`@name` references** — a *polymorphic* reference: `@llm.tools.weather`
  resolves to the file it names; what "pull in" means depends on the target
  (a code file → its text; a tool → the capability).
- **`>` flags** so an agent cell can mix reference kinds, mirroring `llm`'s own:
  `> -T @llm.tools.weather -F @file:foo.py …`  (`-T` tool, `-F` fragment/file).
  `llm` confirmed to support `-T, --tool NAME` and `--functions CODE|FILE`
  (ad-hoc, per-invocation tools) plus `--td`/`--ta` (tool debug / approve).
- **Two install scopes for tools:** doc-scoped via `--functions <file>` (the
  document *is* the toolbox, no install) vs global via the plugins folder +
  `register_tools` (shows in `llm tools list` everywhere). Likely both, with the
  `@`-vs-`@@` count (à la `>`/`>>`) choosing which.

## Open wrinkles to settle when building

- **one file = one tool, or many?** A file can `register()` several functions, so
  the directory view and the `llm tools list` view won't be 1:1. Two lenses;
  fine, just known.
- **inputs on Enter:** does Enter run `main()`, prompt for args, or run a demo?
  The `__main__` block decides, but bsh needs a convention for whether/how it
  passes input (and how stdin/args reach the script).
- ~~**smallest first experiment:** one hardcoded `$BSH_HOME` namespace browser
  (reuse `:` listing) + Enter-dispatch-on-file-type (executable → run by
  shebang, dir → list / `.enter`). Feel whether the dotted-namespace gesture is
  right before generalizing.~~ **BUILT** — see "Namespace cells (built)" below.

## Namespace cells (built)

A bare dotted identifier on its own line that resolves under `$BSH_HOME`
(`vim.env.BSH_HOME`, default `~/pockt/bsh`, "" if it doesn't exist so prose
stays prose) is a cell. `<CR>` (`run_namespace`):

- dots → slashes: `llm.tools.weather` → `$BSH_HOME/llm/tools/weather`
- **directory** → list it (reuses `:` `run_list`); a dir with an executable
  `.enter` runs that instead
- **file** → executed by its shebang into an `out` fence (matches `weather` or
  `weather.<ext>`, since execution is shebang- not extension-driven). A
  dual-purpose `weather.py` runs its `__main__`.
- non-executable file → warns (`chmod +x`); unresolved name → falls through to
  prose (the dispatch is gated on the path existing, checked LAST in
  `execute_cell`, so words like "TODO" never fire).

Verified: `.py` and `.sh` leaves both run by shebang; dir lists; `.enter` runs.

**Refined (built 2026-06-17):**
- Drill *within* a namespace listing now stays dotted: a listing's trigger
  carries a **trailing dot** (`demo.`) so entries resolve as `demo.<child>`;
  subdir → descend+list, file → open in the editor.
- A trailing dot is an explicit **peek/list** operator: `demo.greet.` lists the
  folder even when `demo.greet` (no dot) would run its `.enter`. A plain dir
  without an `.enter` canonicalises its trigger to `name.` and lists. Listings
  pass `-H` so the `.enter` dotfile is visible.

**Still not built:**
- A `:BshHome` entry point to list the root for discovery.
- See "Defining & invoking commands" below for args + authoring.

## Defining & invoking commands (open design, the next big rock)

Three gaps surfaced once the namespace existed: commands take **no args**, there's
no way to **author** one from inside bsh, and a command like `git.undo` needs to
run in **the user's repo**, not the document's dir. Proposed model:

### A unified namespace gesture grammar

| Form | Meaning |
|------|---------|
| `foo.bar` | run (dir → `.enter` or list) |
| `foo.bar.` | peek/list the dir (built) |
| `foo.bar arg1 arg2` | run with args, **through the shell** (built) |
| `foo.bar!` | edit the leaf's source; **scaffold it if missing** |
| `$ bsh foo.bar [args]` | run from any shell/session cell, in the shell's `$PWD` |

### 1. Inline args (`foo.bar arg…`) — BUILT (2026-06-17)

Dispatch now also matches `^(dotted)%s+(.+)$`. Crucially, the leaf is **not**
exec'd as a bare argv — it's resolved to its path and run as a **shell command**
via `$`'s one-shot machinery (`run_ns_exec` → `run_shell(buf,…, shellescape(path)
.. " " .. rest)`). So a namespace cell is a true **continuation of the shell**:
the rest of the line is shell syntax, so redirection (`> out.txt`), pipes
(`| grep`), globs, and sub-shells (`$(…)`) all work, not just positional args.
Runs in the document's dir, like `$`. Still gated on the first token resolving, so
prose (`hello world`) and `<dir> <args>` (no `.enter`) fall through to prose.
Verified: `llm.tools.reverse hello`→`olleh`, `… | tr a-z A-Z`, `reverse "$(echo
abc)"`→`cba`, `weather Izmir > file`. (Conceptually this is the in-buffer twin of
the future `$ bsh foo.bar …` dispatcher; bsh resolves the path itself so it needs
no external binary yet.)

### 2. Define-in-place (`foo.bar!`) — BUILT (2026-06-17)

`!` = "edit source, creating if absent" — mirrors `:Bsh!` (= create/force).
`edit_namespace`:
- **existing leaf** (`bar` or `bar.<ext>`) → opens it in a `:split`.
- **existing directory** → opens its `.enter` (its behavior definition), or offers
  to scaffold one.
- **nothing there** → after a **confirm** (typo-guard, so a stray `word!` line
  can't silently create a file), scaffold an executable leaf and open it.
Scaffolds via `M.scaffold_lang` (`"sh"` default = a plain shell command; `"python"`
= the dual-purpose command/`llm`-tool skeleton with `register_tools` + `__main__`);
parent dirs created, exec bit set, so it's runnable immediately — `demo.newcmd!`
then `demo.newcmd world` works in one loop. Confirm is `M.confirm` (overridable).
One operator covers both "make new command" and "jump to a command's source".

### 3. The `bsh` PATH dispatcher (the keystone for args + cwd)

A tiny launcher binary `bsh` on `$PATH` that resolves a dotted name under
`$BSH_HOME` and `exec`s the leaf **in the caller's `$PWD`**, forwarding args:

```sh
cd ~/myrepo
bsh git.undo            # runs git.undo IN ~/myrepo, not the document's dir
bsh db.prod "select 1"  # args forwarded
```

Why this is the unifier:
- **Solves the cwd problem** (`git.undo` in *your* repo): route through a `$$`
  session that `cd`'d there — `$$ cd ~/myrepo` then `$$ bsh git.undo`.
- **One tree, everywhere:** the same namespace works in a real terminal outside
  nvim, and from `$`/`:` cells — directly answering "should commands be callable
  from the shell?". Yes: via `bsh`.
- In-buffer namespace cells keep running in the doc's dir (fine when the doc
  lives in the repo); for repo-relative work, go through a session + `bsh`.

Open: whether the in-buffer `foo.bar` cell should also honour the buffer's `$$`
session cwd (deeper integration) or stay doc-dir. Lean: keep simple, push
repo-relative through `bsh` in a session.

### Flagship tool use cases (to dogfood + demo)

Pick targets that show the namespace+listing model off, à la Xiki:
- **`db.*` — a database browser/query** (Xiki was loved for this). `db.prod`
  lists tables → `db.prod.users` lists/queries rows into a `dir`/table fence →
  drill a row to expand it. Maps perfectly onto dotted-namespace + drill-in.
- **`git.*` — small sharp commands**: `git.undo` (soft-reset last commit, keep
  changes), `git.wip`, `git.sync`. Great with the `bsh`-in-a-session cwd story.
- Others that fit: `http.get <url>`, `json.*`, `notes.*`, `docker.*`.

## Output to a side buffer (a gesture, not a marker) — BUILT (2026-06-17)

**Built:** `<C-CR>` / `g<CR>` runs a cell with output into a side buffer instead of
inline, across **every output cell type**: `$`, `$$` shell session, `python $`
one-shot, `python $$` session, and namespace cells. The buffer is an unbounded
`nofile` scratch named `bsh://out/<doc>/<n>`; that name is written into an owned
` ```log ` reference fence and IS the durable link; `out_bufs` caches name→bufnr.
`buffer_sink` writes output in (follow/autoscroll) and keeps the reference line's
status (`<link> · N lines · running…/exit C · <CR> open`). One helper
`begin_buffer_run` (reuse/mint buffer + clear + stage `log` fence + sink) is the
single fork in each run path; `run_job` takes the sink for streamed cells, and the
session pump hands the sink to its queue item and calls it instead of `fill_fence`
(a `$$` fence is pure output, so it's the same as `$` — it just fills on unit
completion rather than streaming). Re-run reuses the linked buffer (only
`ensure_out_buffer` mints a new one when there's no live link); a cell that owns a
`log` fence is sticky on a plain `<CR>` too; `<CR>` on the reference line opens the
buffer (`open_out_buffer`). `log` is in `OWNED_TAGS` so re-runs replace the fence.

**Deliberately NOT routed:** `:` listings — their output IS interactive (in-fence
drill/open), so it must stay in the doc fence. **Not yet:** persist-on-`:w` to a
real `bsh:file:` path; an explicit stop keymap (re-run already restarts;
`M.stop_session` on wipe); live streaming for `$$` sessions (they fill on unit
completion, pre-existing).

Original rationale + spec below.

Some output shouldn't live inline under the cell: long build logs, `tail -f`, a
dev server, anything you want to scroll/search separately. The cell should leave a
compact **reference**, and the bytes should live in a **separate buffer**.

**Design pivot (2026-06-17): there is NO `%` marker.** `%` had been a stand-in for
"async / long-running / buffered output", but:

- **async is already universal** — every cell runs via `jobstart` and streams, so
  `%`-as-async would mark something every cell already is.
- **where output goes (inline vs side buffer) is ORTHOGONAL** to run semantics — a
  `$`, `$$`, `python`, namespace, or `:` cell could each want either. Orthogonal
  properties belong in a **gesture**, not a marker (markers are for run *kind*).
- **background/`&`** (fire-and-forget, drop output) mostly already works via
  `$ cmd &` (the shell backgrounds it, child reparents to init); a dedicated `&`
  marker would only add explicit detach — marginal, not built.

So: output destination is a **second keybinding**, available on **every** cell:

- `<CR>`  → output inline (today's behavior).
- `<C-CR>` → run, but stream output into a **side buffer** (the long-runner /
  log use case, for any command).
- Portability: `<C-CR>` is only distinct from `<CR>` under the kitty keyboard
  protocol (the user's `foot` qualifies); also bind a universal fallback
  (`g<CR>` or a `<localleader>` map) for plain terminals / SSH.

The side buffer (hard constraint the user named: it **does not necessarily exist
on disk and must not be persisted preemptively** — huge / infinite / sensitive):

- **Ephemeral + unbounded:** a scratch `nofile` buffer `bsh://out/<doc>/<n>` that
  accumulates ALL output (user's call: completeness over OOM-safety — a 50k-line
  build log stays whole; a runaway `tail -f` is stopped by hand), with
  follow/autoscroll and an easy **stop**.
- **The cell shows a reference fence**, not content — an owned ` ```log ` fence
  with a one-line live status:

  ```
  $ ./build.sh
  ```log
  bsh://out/build.sh · 4213 lines · exit 0 · <CR> open · :w persist
  ```
  ```

- **The link lives in the fence text** (not a fragile in-memory map): the
  `bsh://out/<doc>/<n>` **buffer name** written in the ` ```log ` body *is* the
  handle — `vim.fn.bufnr("bsh://out/…")` recovers it. The fence is the source of
  truth.
- **Create a buffer only if the fence doesn't already link a live one** (the
  reuse rule the mechanism turns on): on (re-)run, read the cell's existing owned
  fence; if it's a `log` fence whose linked buffer is still valid, **reuse** it
  (clear the ring, stream in) — do **not** spawn a new buffer. Only mint a fresh
  `bsh://out/<doc>/<n>` when there's no link or the linked buffer is gone. So
  re-running a `tail -f` / dev-server cell keeps hitting the same buffer instead
  of littering new ones.
- **Sticky routing falls out of the same fact:** because the `log` fence carries
  the link, a plain `<CR>` on a cell that already owns one keeps routing to that
  buffer (no need to re-`<C-CR>`); the trigger line is never touched. Delete the
  fence to revert to inline. So `<C-CR>` opts a cell in once; it stays in.
- **Persist on demand only:** `:w` in the side buffer (or a keymap on the
  reference) writes to `$XDG_CACHE_HOME/bsh/…` and rewrites the fence link to a
  real `bsh:file:<path>` that survives reopen. Disk is opt-in.
- **Lifecycle:** killing the doc/cell stops the job (inflight jobs + BufWipeout →
  stop_session already); wiping the side buffer stops it too.

Optional later — **auto-spill threshold:** a plain inline `<CR>` whose output
exceeds N lines auto-collapses to the same reference fence ("(N more lines) →
open"), so you needn't pre-choose. Same machinery.

## Interactivity (PTY / password prompts) — parked

bsh runs cells via `jobstart` with **stdin closed** (commands see EOF), so
anything that needs to prompt or hold a TTY can't work today. Two cases, handled
differently:

- **Password prompts (sudo/su/ssh/git)** — no full PTY needed. Provide an
  **askpass shim**: bsh sets `SUDO_ASKPASS` / `SSH_ASKPASS` (+
  `SSH_ASKPASS_REQUIRE=force`) / `GIT_ASKPASS` to a tiny helper that calls back
  into nvim, prompts with `vim.fn.inputsecret()`, and echoes the secret on
  stdout. Output still streams inline; only the secret is sidebarred. (Caveat:
  `sudo` needs `-A`; ssh/git pick up the env var without flags. A `sudo` wrapper
  on `$BSH_HOME`/PATH that adds `-A` could paper over that.)
- **Genuinely interactive tools (REPLs, `fzf`, `vim`, `top`, `git rebase -i`)** —
  need a real TTY. Escape-hatch marker **`$!`** ("shell, interactive", bang =
  special, consistent with `:Bsh!` / `foo.bar!`): run the command in a **PTY**
  via `termopen()`/`jobstart({pty=true})`, in a **floating terminal by default**
  (user dislikes the nvim terminal split; float is least intrusive), configurable
  to split or an external emulator (`$TERMINAL -e …`). The terminal is the
  easiest path that genuinely works. Later: capture the PTY output back into the
  cell's fence on exit (needs control-code stripping).

## External display (images / GUI) — parked, no action

GUI apps already work (`$ firefox` launches Firefox). Inline **images** /
image-generating commands: park until Neovim has native image handling; then show
in a **floating window** via a terminal graphics protocol (image.nvim /
snacks.image). User explicitly wants to wait on an upstream nvim feature here.

## Embedded LSP via otter.nvim — parked (worth exploring)

Let code fences get real LSP (Python/Ruby/… inside the doc) by feeding
[otter.nvim](https://github.com/jmbuhr/otter.nvim) the fenced code as synthetic
per-language documents. **Known limitation to design around:** otter gives
*static* analysis of fence *source*; it can't see `$$` / `python $$` **runtime**
state — a variable created by *executing* an earlier cell lives in the live
session process, not the text, so the LSP would flag it "undefined". That gap is
inherent to static analysis, not a bug. Neat alignment to exploit: feed *all* of
a buffer's `python $$` cells as **one** otter document, so statically-defined
symbols carry across cells the same way the session accumulates them — otter's
per-language concatenation ≈ the session's accumulated namespace. Probably out of
scope for bsh proper (a user can add otter themselves), but bsh could expose the
cell ranges/order to make it work well. It's also worth remembering that `$$`
does not only connect visible `$$` instances, but even absent ones. A user can
mutate the state in a `$$` then delete it from the file, yet the mutation is
still in the state and the lsp will still be unaware of it even if all `$$`
cells were given to it for context.

## Other roadmap bits (parked)

- **Prompt loop** for the shell-first feel: run → drop a fresh `$$ ` prompt below
  in insert mode; plus Ctrl-C interrupt (we already track the job) and a
  pwd-aware prompt.
- **Side-buffer output / long-runner** → specced above ("Output to a side
  buffer"): a `<C-CR>` gesture (no `%` marker) → bounded ring buffer + reference
  fence + sticky-via-`log`-fence + persist-on-`:w`.
- **Interactive tree**: replace the `tree -F` text dump with a lazy,
  inline-expandable tree (folders expand/collapse in place, children listed on
  demand) — structure lives in indentation, no `tree` dependency, no upfront
  full dump. Same gesture as the namespace browser above. **Motivated by:** the
  current `tree` fence can't **fold subtrees** — it's a flat dump, so you can't
  collapse a branch you don't care about. Lazy expand-in-place gives folding for
  free (a collapsed node just doesn't list its children) and fixes big-tree perf
  at the same time. (Interim cheaper option if needed: a tree-aware `foldexpr`
  that folds by `tree -F` indentation depth — but expand-in-place is the real
  fix.)
