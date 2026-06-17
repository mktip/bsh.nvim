-- User-tunable options: the single source of truth read by the engine modules.
-- The public surface `require('bsh').<opt>` proxies here (see init.lua), so
-- `require('bsh').python = 'python3.12'` and reads keep working.
local M = {}

-- Remote (`user@host$ cmd`) cells run in a login shell so the remote profile
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

-- Yes/no gate before `foo.bar!` creates a NEW file (so a stray `word!` line can't
-- silently scaffold). Overridable for customisation / tests; return true = go.
function M.confirm(prompt)
  return vim.fn.confirm(prompt, "&Yes\n&No", 2) == 1
end

return M
