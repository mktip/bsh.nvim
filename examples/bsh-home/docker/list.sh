#!/usr/bin/env bash
# docker.list — manage ALL containers (running or not): start / stop / restart /
# rm, or drop into a shell.
#
#   docker.list                 <CR> -> a menu of every container           (exit 150)
#   <CR> on a row                    -> an actions menu                     (exit 150)
#   <CR> on an action                -> runs it (shell emits a cell)        (exit 0/151)
#
# `shell` reuses the same emit-a-cell handoff as docker.conn; the rest print
# docker's own output into a terminal `out` fence.
set -euo pipefail

case $# in
  0)
    # every container, with its state, so you can see what's stopped vs running.
    docker ps -a --format '{{.ID}}  {{.State}}  {{.Image}}  {{.Names}}'
    exit 150
    ;;
  1)
    # a container row was picked -> offer the actions (drilling re-runs with the
    # action appended as the 2nd arg).
    echo shell
    echo start
    echo stop
    echo restart
    echo rm
    exit 150
    ;;
  *)
    id=${1%% *}            # first field of the picked row = the id
    action=$2
    case $action in
      shell)   printf 'docker@%s$$ \n' "$id"; exit 151 ;;  # hand back a session cell
      start)   docker start "$id" ;;
      stop)    docker stop "$id" ;;
      restart) docker restart "$id" ;;
      rm)      docker rm -f "$id" ;;
      *)       echo "unknown action: $action" >&2; exit 1 ;;
    esac
    ;;
esac
