-- User-tunable options: the single source of truth read by the engine modules.
-- The public surface `require('bsh').<opt>` proxies here (see init.lua), so
-- `require('bsh').python = 'python3.12'` and reads keep working.
local M = {}

-- The RUN MARKER: the symbol that turns a line into a shell cell. A single
-- trailing one (`<marker> cmd`) runs once; doubled (`<marker><marker> cmd`) runs
-- in a persistent session. It is a SUFFIX after the route (`user@host<marker>`)
-- so the language/route stays first. Everything in the engine reads this -- the
-- trigger parser, the fence info-string parser, the cell-emitting commands -- so
-- changing the shell's symbol is one edit here. `$` collides with Typst math, so
-- the default is `%` (free in Typst, csh/zsh prompt heritage). Set it back to
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
--                    podman = { "podman", "exec", "-i", "{addr}", "sh", "-lc", "{cmd}" }
--                    kube = { "kubectl", "exec", "-i", "{addr}", "--", "sh", "-lc", "{cmd}" }
--                    vm = { "ssh", "-T", "{addr}.vm.lan", "{cmd}" }   -- a bhyve/kvm guest
M.transports = {
  docker = { "docker", "exec", "-i", "{addr}", "sh", "-lc", "{cmd}" },
}

-- `> instruction` agent cells call `llm -t <template>`; the default `web`
-- template carries tools (search/fetch), so a `>` after a link can summarise it.
-- Point this at a more agentic template if you make one.
M.agent_template = "web"

-- interpreter used for `python` cells (one-shot `python $` and session `python $$`).
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
-- of output. The keystone of "pick X -> get a `docker@<id>$$` session cell": a
-- menu drill (exit 150) narrows to a target, then a terminal action exits this
-- code printing e.g. `docker@<id>$$ ` and bsh swaps the breadcrumb for that cell.
M.cell_exit = 151

-- Yes/no gate before `foo.bar!` creates a NEW file (so a stray `word!` line can't
-- silently scaffold). Overridable for customisation / tests; return true = go.
function M.confirm(prompt)
  return vim.fn.confirm(prompt, "&Yes\n&No", 2) == 1
end

return M
