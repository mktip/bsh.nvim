#!/usr/bin/env bash
# containers : pick a running container, get a session cell inside it.
#   containers              -> menu of running podman/docker containers here (exit 150)
#   containers <host>       -> the same, on an ssh host (`containers me@server`)
#   containers [host] <line> -> emits `[host/]<runtime>@<name>%% ` (exit 151), a
#                              persistent shell in that container (over ssh first)
# Menu lines are `<runtime>@<name>  <image>  <status>`. A name running under both
# runtimes (Fedora's podman-docker shim makes `docker` list podman's containers)
# is listed once, by the first runtime in BSH_CONTAINER_RUNTIMES.
runtimes=${BSH_CONTAINER_RUNTIMES:-podman docker}

host= line=
for a in "$@"; do
  case $a in *' '*) line=$a ;; *) host=$a ;; esac # a menu line has spaces, a host doesn't
done

if [ -n "$line" ]; then
  m=${BSH_MARKER:-%}
  printf '%s%s%s%s \n' "${host:+$host/}" "${line%% *}" "$m" "$m"
  exit 151
fi

run() { if [ -n "$host" ]; then ssh -T "$host" "$1"; else sh -c "$1"; fi; }

rows=$(
  for r in $runtimes; do
    run "command -v $r >/dev/null 2>&1 && $r ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}'" 2>/dev/null |
      sed "s/^/$r@/"
  done | awk -F'\t' '{ n = $1; sub(/^[^@]*@/, "", n) } !seen[n]++'
)
if [ -z "$rows" ]; then
  echo "no running containers${host:+ on $host}"
  exit 0
fi
printf '%s\n' "$rows" | awk -F'\t' '
  { t[NR] = $1; i[NR] = $2; s[NR] = $3; if (length($1) > w) w = length($1); if (length($2) > v) v = length($2) }
  END { for (k = 1; k <= NR; k++) printf "%-*s  %-*s  %s\n", w, t[k], v, i[k], s[k] }'
exit 150
