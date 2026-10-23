#!/usr/bin/env bash
# ssh : pick a host from ~/.ssh/config, get a session cell for it.
#   ssh          -> menu of Host aliases (exit 150, drillable; <CR> on one drills)
#   ssh <host>   -> emits `<host>%% ` (exit 151), replacing this trigger with a
#                   persistent-session cell on that host
# Aliases come from `Host` lines (wildcards skipped), following `Include`s.
# Set BSH_SSH_KNOWN=1 to also list hosts from ~/.ssh/known_hosts.
conf=${BSH_SSH_CONFIG:-$HOME/.ssh/config}

files() { # config + any Include'd files (relative paths resolve under ~/.ssh)
  [ -r "$1" ] || return 0
  echo "$1"
  awk 'tolower($1)=="include"{for(i=2;i<=NF;i++)print $i}' "$1" | while read -r g; do
    case $g in /*|~*) ;; *) g="$HOME/.ssh/$g" ;; esac
    for f in $(eval echo "$g" 2>/dev/null); do [ -f "$f" ] && echo "$f"; done
  done
}

hosts() {
  files "$conf" | xargs -r awk 'tolower($1)=="host"{for(i=2;i<=NF;i++) if($i !~ /[*?!]/) print $i}'
  if [ -n "$BSH_SSH_KNOWN" ] && [ -r "$HOME/.ssh/known_hosts" ]; then
    awk '!/^[|@]/{split($1,a,","); gsub(/^\[|\]:[0-9]+$/,"",a[1]); print a[1]}' "$HOME/.ssh/known_hosts"
  fi
}

case $# in
  0) hosts | awk '!seen[$0]++'; exit 150 ;;
  *) m="${BSH_MARKER:-%}"; printf '%s%s%s \n' "$1" "$m" "$m"; exit 151 ;;
esac
