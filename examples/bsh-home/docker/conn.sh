#!/usr/bin/env bash
# docker.conn — pick a RUNNING container, get a persistent shell in it.
#
#   docker.conn          <CR> -> a menu of running containers           (exit 150)
#   <CR> on a row             -> emits a `docker@<id>$$ ` session cell   (exit 151)
#
# The emitted cell is a live container shell (see "Targets are routes" — `$$`
# composes over the docker transport), so env/cwd carry across cells in it.
set -euo pipefail

case $# in
  0)
    # one row per running container; the first field (the id) is what we drill on.
    docker ps --format '{{.ID}}  {{.Image}}  {{.Names}}'
    exit 150
    ;;
  *)
    # the drilled menu line arrives as one quoted arg ("<id>  <image>  <name>");
    # take its first field as the container id and hand back a session cell for it.
    id=${1%% *}
    printf 'docker@%s$$ \n' "$id"
    exit 151
    ;;
esac
