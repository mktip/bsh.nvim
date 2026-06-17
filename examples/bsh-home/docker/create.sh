#!/usr/bin/env bash
# docker.create — spin up a throwaway container and hand back a shell in it.
#
#   docker.create          <CR> -> a container named `bsh-<epoch>`
#   docker.create web      <CR> -> ... named `web`
#
# Defaults to alpine, kept alive with `sleep infinity` so you can exec into it
# (a bare `alpine` would exit immediately and there'd be nothing to attach to).
# Override the image with IMG=… in the cell: `IMG=debian docker.create dev`.
# On success it EMITS a `docker@<name>$$ ` cell (exit 151), so create-then-shell
# is a single <CR>.
set -euo pipefail

img=${IMG:-alpine}
name=${1:-bsh-$(date +%s)}

docker run -d --name "$name" "$img" sleep infinity >/dev/null
printf 'docker@%s$$ \n' "$name"
exit 151
