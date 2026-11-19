#!/bin/sh
# Run the suite: each test file in its own headless Neovim, $JOBS at a time
# (default: one per CPU). Prints each file's report, then fails if any file did.
#   tests/run.sh                       every tests/test_*.lua
#   tests/run.sh tests/test_agent.lua  just these
set -u
cd "$(dirname "$0")/.." || exit 1
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

one() {
  log="$2/$(basename "$1" .lua).log"
  if nvim --headless --noplugin -u tests/minimal_init.lua \
    -c "lua MiniTest.run_file('$1')" >"$log" 2>&1; then
    : >"$log.ok"
  fi
}

[ $# -gt 0 ] || set -- tests/test_*.lua
jobs=${JOBS:-$(nproc 2>/dev/null || echo 4)}

# a small job pool in plain sh: start up to $jobs, wait for the batch
i=0
for f in "$@"; do
  one "$f" "$out" &
  i=$((i + 1))
  if [ "$i" -ge "$jobs" ]; then wait; i=0; fi
done
wait

failed=""
for f in "$@"; do
  log="$out/$(basename "$f" .lua).log"
  if [ -e "$log.ok" ]; then
    printf '%-32s ok\n' "$f"
  else
    failed="$failed $f"
    printf '%-32s FAILED\n' "$f"
  fi
done
for f in $failed; do
  printf '\n==== %s ====\n' "$f"
  cat "$out/$(basename "$f" .lua).log"
done
[ -z "$failed" ]
