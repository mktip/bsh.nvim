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
| `foo.bar arg1 arg2` | run, passing args as `argv` to the leaf |
| `foo.bar!` | edit the leaf's source; **scaffold it if missing** |
| `$ bsh foo.bar [args]` | run from any shell/session cell, in the shell's `$PWD` |

### 1. Inline args (`foo.bar arg…`)

Relax `run_namespace`'s "line must be *just* the dotted name" rule to
`^(dotted)%s+(.+)$`: shell-word-split the rest into `argv` and pass it to the
executable (`weather.py` already reads `sys.argv[1]`). Still gated on the first
token resolving to a real leaf, so prose stays prose. This is the obvious,
shell-like answer for the in-buffer case.

### 2. Define-in-place (`foo.bar!`)

`!` = "edit source, creating if absent" — mirrors `:Bsh!` (= create/force). On an
**unresolved** name, scaffold `$BSH_HOME/foo/bar` (executable, with a shebang +
`__main__`/`register_tools` skeleton) and open it in a split; on an **existing**
leaf, just open it to edit. One operator covers both "make new command" and "jump
to a command's source". Explicit, so a typo never auto-creates a file (keeps the
"unresolved → prose" guarantee for the no-bang form).

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

## Other roadmap bits (parked)

- **Prompt loop** for the shell-first feel: run → drop a fresh `$$ ` prompt below
  in insert mode; plus Ctrl-C interrupt (we already track the job) and a
  pwd-aware prompt.
- **`%` long-runner** → stream into a bounded (ring) log buffer and leave a
  follow-link in the `out` fence. nvim has bounded scrollback via `:terminal`'s
  `'scrollback'`; a normal buffer is trivially ring-able.
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
