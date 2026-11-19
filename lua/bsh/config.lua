-- User-tunable options: the single source of truth read by the engine modules.
-- The public surface `require('bsh').<opt>` proxies here (see init.lua), so
-- `require('bsh').python = 'python3.12'` and reads keep working.
local M = {}

-- The RUN MARKER: the symbol that turns a line into a shell cell. A single
-- trailing one (`<marker> cmd`) runs once; doubled (`<marker><marker> cmd`) runs
-- in a persistent session. It is a SUFFIX after the route (`user@host<marker>`)
-- so the language/route stays first. Everything in the engine reads this -- the
-- trigger parser, the fence info-string parser, the cell-emitting commands -- so
-- changing the shell's symbol is one edit here. The default is `%` (csh/zsh
-- prompt heritage, and it doesn't read like a pasted `$` prompt). Set it to
-- `"$"` for the classic look. Child processes see it as $BSH_MARKER (so a
-- cell-emitting namespace command prints the right symbol).
M.marker = "%"

-- Remote (`user@host% cmd`) cells run in a login shell so the remote profile
-- and bashrc load (PATH, pkg, env). Set false for a bare, faster `ssh host cmd`
-- when the remote already has the env you need or you want zero startup files.
M.remote_login = true

-- Transports: how a `scheme@addr` hop reaches a shell. The directory tree of the
-- engine hardcodes nothing but ssh -- everything else (containers, jails, VMs) is
-- yours to define here, one line each. A value is an argv TEMPLATE with two holes:
--   {addr} -- the container/jail/host id (always substituted literally)
--   {cmd}  -- the inner command; passed raw when it's the whole element (a direct
--             `sh -lc {cmd}` slot), shell-escaped when embedded in a bigger word.
-- Or a function(addr, inner) -> argv for full control. The scheme name is the key.
-- ssh is built in (and honours remote_login); add to / override this table freely.
-- Examples to copy:  jail = { "jexec", "{addr}", "sh", "-lc", "{cmd}" }
--                    kube = { "kubectl", "exec", "-i", "{addr}", "--", "sh", "-lc", "{cmd}" }
--                    vm = { "ssh", "-T", "{addr}.vm.lan", "{cmd}" }   -- a bhyve/kvm guest
-- Route aliases: a name standing for a route (or the start of one). Any `/`
-- segment that is an alias expands, so `api%% ps` and `box/podman@db% ls` work:
--   routes = { box = "me@server", api = "me@server/podman@api" }
-- An alias wins over an ssh host of the same name.
M.routes = {}

M.transports = {
  docker = { "docker", "exec", "-i", "{addr}", "sh", "-lc", "{cmd}" },
  podman = { "podman", "exec", "-i", "{addr}", "sh", "-lc", "{cmd}" },
}

-- Your own cell kinds, tried before the built-in ones (first match wins), like
-- Plan 9 plumbing rules: { match = <lua pattern>, run = function(ctx, ...) }.
-- `run` gets the pattern's captures; it may return a shell command (run as a `%`
-- cell, output below the line), false to let the line fall through, or nothing
-- once it has handled the line itself (often via ctx.run, which streams a
-- command into the cell's own fence). Optional: prompt, tag, fold, attach.
-- See bsh.cell (the rule fields), bsh._rule_ctx (ctx), and the `>` agent in
-- lua/bsh/contrib/agent.lua, written entirely this way.
--   rules = { { match = "^%s*(%u+%-%d+)%s*$", run = function(_, id)
--     vim.ui.open("https://jira.example.com/browse/" .. id) end } }
M.rules = {}

-- Inline output stops after this many lines (the rest is counted, not shown; g<CR>
-- sends everything to a side buffer instead). false = no cap.
M.output_max_lines = 2000

-- The `>` agent cells are a bundled rule (lua/bsh/contrib/agent.lua): their
-- options (agent, agent_thread, agent_tools, ...) live there, and are set like
-- any other. `agent = false` turns `>` cells off.

-- How long a cell took and how it ended, as dim text at the end of its trigger
-- line (`running 4s…`, then `1.3s · ok` / `0.2s · exit 1`). Not written into
-- the file. Listings only show it when slow or failed. false = off.
M.status = true

-- ANSI escapes in output (colours from `ls --color`, `bsc_quota`, pytest...):
-- the buffer always gets clean text (a saved file never holds escape codes);
-- "color" shows the colours/bold/underline as highlights over it, "strip" drops
-- them, false leaves the raw escapes in. Cursor moves, screen clears and
-- hyperlink codes are removed in both "color" and "strip".
M.ansi = "color"

-- Completion in shell cells, from wherever the cell runs (commands from that
-- route's PATH, paths from its cwd). Only on request: <C-x><C-o>, nvim-cmp's
-- trigger (a `bsh` source is added to bsh buffers), or <Tab> without nvim-cmp.
-- false = leave 'omnifunc' and <Tab> alone.
M.complete = true

-- Command history, per route (aliases resolved, so `box%` and `me@server%`
-- share one). <C-p>/<C-n> on a prompt line walk it, filtered by what you've
-- typed; :BshHistory / <localleader>h opens it as a buffer. Newest first: what
-- you ran through bsh on that route, then (history_shell) that machine's own
-- shell history file, read over the route once per session.
M.history = true
M.history_shell = true
M.history_max = 5000                 -- entries kept per route
M.history_dir = false                -- false = stdpath("state") .. "/bsh/history"

-- More languages for ```lang % (once) and ```lang %% (a persistent process)
-- blocks, local or along a route (```sqlite me@server%%). Each is:
--   cmd      shell command; a one-shot gets the block on its stdin
--   session  command for a %% process, if different (e.g. a REPL's -i flag)
--   print    a statement in that language printing its argument, with %s
--            where bsh puts a marker: it's how bsh knows a block's output ended
--   prompt   (optional) a prompt the REPL prints, removed from output lines
-- e.g. languages = {
--   sqlite = { cmd = "sqlite3 -batch app.db", print = ".print %s" },
--   node = { cmd = "node", session = "node -i", print = 'console.log("%s")', prompt = "> " },
--   lua = { cmd = "lua -", session = "lua -i", print = 'print("%s")', prompt = "> " } }
-- A session can't report an exit code, so its cells always end `ok`.
M.languages = {}

-- interpreter used for `python` cells (one-shot `python %` and session `python %%`).
M.python = "python3"

-- Optional otter.nvim integration: real LSP (completion, hover, go-to-def,
-- diagnostics) INSIDE ```python fences -- otter mirrors each fence into a hidden
-- buffer and attaches a language server to it (use your normal pyright/ruff).
--   "auto"  -> enable iff otter.nvim is installed (a no-op otherwise) -- default
--   true    -> force on; warn once if otter.nvim is missing
--   false   -> off
-- bsh has no hard dependency on otter; everything is pcall-guarded. See
-- lua/bsh/otter.lua and the README ("LSP inside code blocks").
M.otter = "auto"

-- Languages otter activates inside fences. `python` is the one bsh runs; add
-- more (e.g. "lua") if you keep other fenced code you want LSP for.
M.otter_languages = { "python" }

-- language a `foo.bar!` define-in-place scaffolds a NEW leaf in: "sh" (a plain
-- shell command, lowest friction) or "python" (the dual-purpose command/`llm`
-- tool skeleton). Cosmetic extension only; dispatch stays shebang-driven.
M.scaffold_lang = "sh"

-- Exit code a namespace command returns to DECLARE its output a drillable menu:
-- bsh renders it as a ```menu fence (not ```out, and the code isn't shown as an
-- error), and plain <CR> on any of its lines re-runs the command with that line
-- appended as one more arg (drill). 150 is outside the common 0-128 range; change
-- it if it clashes with a real exit code your commands use.
M.menu_exit = 150

-- Exit code a namespace command returns to EMIT A CELL: its first output line is
-- treated as cell text that REPLACES the trigger (the dotted/breadcrumb line) and
-- its result fence -- so a command can hand back a new, ready-to-run cell instead
-- of output. The keystone of "pick X -> get a `docker@<id>%%` session cell": a
-- menu drill (exit 150) narrows to a target, then a terminal action exits this
-- code printing e.g. `docker@<id>%% ` and bsh swaps the breadcrumb for that cell.
M.cell_exit = 151

-- Whether a finished SESSION (`<marker><marker>`) shell cell trails its prompt
-- line with the shell's cwd as eol virt_text -- `web@prod:/var/log` for a remote,
-- the bare path locally. It mirrors a shell prompt, which is the case for it; the
-- case against is that a session line is read as part of a DOCUMENT, and a path
-- that materialises next to it only after you run it makes the line jitter and
-- reads as noise in a file meant to be shared. Off for that reason; set true to
-- get the badge back. Only `sh` sessions ever showed one -- the python driver's
-- sentinel carries no pwd.
M.prompt_badge = false

-- Yes/no gate before `foo.bar!` creates a NEW file (so a stray `word!` line can't
-- silently scaffold). Overridable for customisation / tests; return true = go.
function M.confirm(prompt)
  return vim.fn.confirm(prompt, "&Yes\n&No", 2) == 1
end

return M
