#!/usr/bin/env bash
# demo.menu : a self-feeding menu. With no args it lists items; <C-CR> on an
# item re-runs `demo.menu <item>` (drill) showing actions; <C-CR> on an action
# re-runs `demo.menu <item> <action>`. The command inspects "$@" to decide.
case $# in
  0) echo "alpha"; echo "beta" ;;
  1) echo "$1 selected"; echo "start"; echo "stop" ;;
  *) echo "$2 -> $1" ;;
esac
