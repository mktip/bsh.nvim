#!/usr/bin/env bash
# demo.conn — a docker-free demonstration of the menu (exit 150) + emit-a-cell
# (exit 151) primitives, so the cell-handoff flow is testable without docker:
#   demo.conn            -> a menu of "ids"        (exit 150, drillable)
#   demo.conn <id>       -> a menu of actions      (exit 150)
#   demo.conn <id> open  -> emits a session cell   (exit 151, replaces the trigger)
case $# in
  0) echo one; echo two; exit 150 ;;
  1) echo open; echo close; exit 150 ;;
  *) printf 'fake@%s$$ \n' "$1"; exit 151 ;;
esac
