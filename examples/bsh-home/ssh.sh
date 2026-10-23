#!/usr/bin/env bash
# ssh : pick a host, get a session cell for it.
#   ssh          -> menu of hosts you've used or configured (exit 150, drillable)
#   ssh <line>   -> emits `<target>%% ` (exit 151): a persistent-session cell
# Each menu line is `<target>  <user>@<hostname>[:port]  <source>`; the first word is
# what the session cell connects to. Sources, in order:
#   config   `Host` aliases in ~/.ssh/config (+ Includes); user/hostname resolved by
#            `ssh -G`, so `User`, `HostName` and `Host *` defaults are all honoured
#   history  `ssh [user@]host` typed in your bash/zsh/fish history (this is where
#            usernames you gave on the command line live; known_hosts has none)
#   known    ~/.ssh/known_hosts entries not already listed (hashed entries are
#            unreadable and skipped; user shown is ssh's default for that host)
# BSH_SSH_CONFIG overrides the config path; BSH_SSH_SOURCES="config history known"
# picks which sources to read.
conf=${BSH_SSH_CONFIG:-$HOME/.ssh/config}
sources=${BSH_SSH_SOURCES:-config history known}

files() { # config + any Include'd files (relative paths resolve under ~/.ssh)
  [ -r "$1" ] || return 0
  echo "$1"
  awk 'tolower($1)=="include"{for(i=2;i<=NF;i++)print $i}' "$1" | while read -r g; do
    case $g in /*|~*) ;; *) g="$HOME/.ssh/$g" ;; esac
    for f in $(eval echo "$g" 2>/dev/null); do [ -f "$f" ] && echo "$f"; done
  done
}

config_hosts() {
  files "$conf" | xargs -r awk 'tolower($1)=="host"{for(i=2;i<=NF;i++) if($i !~ /[*?!]/) print $i}'
}

history_targets() { # user@host / host from `ssh ...` lines in shell histories
  { cat "$HOME/.bash_history" "$HOME/.zsh_history" 2>/dev/null
    sed -n 's/^- cmd: //p' "$HOME/.local/share/fish/fish_history" 2>/dev/null; } |
  awk '
    BEGIN { split("-p -i -l -o -J -F -L -R -D -b -c -E -e -I -m -O -S -W -w", a, " "); for (i in a) arg[a[i]] = 1 }
    { sub(/^: [0-9]+:[0-9]+;/, "") }                 # zsh extended history prefix
    {
      for (i = 1; i <= NF; i++) if ($i == "ssh" && (i == 1 || $(i-1) ~ /^(sudo|exec|command|time|\||&&|;)$/)) {
        for (j = i + 1; j <= NF; j++) {
          if ($j in arg) { j++; continue }
          if ($j ~ /^-/) continue
          if ($j ~ /^[A-Za-z0-9_.@-]+$/) print $j
          break
        }
        break
      }
    }' | sort | uniq -c | sort -rn | awk '{print $2}'
}

known_targets() {
  [ -r "$HOME/.ssh/known_hosts" ] || return 0
  awk '!/^[#|@]/ && NF { n = split($1, a, ","); for (i = 1; i <= n; i++) { h = a[i]; sub(/^\[/, "", h); sub(/\]:[0-9]+$/, "", h); print h } }' \
    "$HOME/.ssh/known_hosts"
}

# resolve <target> through ssh -G -> "user hostname port"
resolve() {
  local f=(); [ -r "$conf" ] && f=(-F "$conf")
  ssh -G "${f[@]}" "$1" 2>/dev/null | awk '$1=="user"{u=$2} $1=="hostname"{h=$2} $1=="port"{p=$2} END{print u, h, p}'
}

list() {
  declare -A seen hosts
  rows=()
  add() { # target source
    local t=$1 src=$2 u h p key
    read -r u h p < <(resolve "$t")
    [ -n "$h" ] || return
    key="$u@$h:$p"
    # every config alias is listed; history/known skip what's already there
    # (known also skips any host a config entry already points at)
    if [ "$src" != config ]; then
      [ -z "${seen[$key]}" ] || return
      [ "$src" != known ] || [ -z "${hosts[$h]}" ] || return
    fi
    seen[$key]=1; hosts[$h]=1
    [ "$p" = 22 ] && p= || p=":$p"
    rows+=("$t	$u@$h$p	$src")
  }
  for s in $sources; do
    case $s in
      config)  while read -r t; do [ -n "$t" ] && add "$t" config; done < <(config_hosts) ;;
      history) while read -r t; do [ -n "$t" ] && add "$t" history; done < <(history_targets) ;;
      known)   while read -r t; do [ -n "$t" ] && add "$t" known; done < <(known_targets | awk '!s[$0]++') ;;
    esac
  done
  [ ${#rows[@]} -gt 0 ] || return
  printf '%s\n' "${rows[@]}" | awk -F'\t' '{ t[NR]=$1; r[NR]=$2; s[NR]=$3; if (length($1)>w) w=length($1); if (length($2)>v) v=length($2) }
    END { for (i=1;i<=NR;i++) printf "%-*s  %-*s  %s\n", w, t[i], v, r[i], s[i] }'
}

case $# in
  0) list; exit 150 ;;
  *) m="${BSH_MARKER:-%}"; target=${1%% *}; printf '%s%s%s \n' "$target" "$m" "$m"; exit 151 ;;
esac
