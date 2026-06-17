#!/usr/bin/env bash
# demo.menu : a self-feeding menu. Exiting 150 (bsh's menu_exit) DECLARES the
# output a menu -- each line is then a valid next arg, and <CR> on one re-runs
# `demo.menu <line>` (drill). A normal exit (0) is a terminal result, not a menu.
case $# in
  0) echo "alpha"; echo "beta"; exit 150 ;;            # top menu
  1) echo "$1 selected"; echo "start"; echo "stop"; exit 150 ;; # sub-menu
  *) echo "$2 -> $1" ;;                                # terminal action (exit 0)
esac
