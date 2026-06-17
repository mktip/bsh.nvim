#import "template.typ": cell, bsh
#import "hosts.typ": hosts
#show: bsh.with(hosts: hosts)

= A bsh session, typeset

You write your prompt as one character. Below, the owned `#cell` is what bsh
emits on `<CR>` — structured, so it renders as a card.

// % ls -al
#cell(cmd: "ls -al", host: none, cwd: "~/pockt", code: 0)[```
total 24
drwxr-xr-x  5 mktips mktips 4096 Jun 17 .
drwxr-xr-x 31 mktips mktips 4096 Jun 17 ..
-rw-r--r--  1 mktips mktips  812 Jun 17 README.md
-rw-r--r--  1 mktips mktips 1.3K Jun 17 template.typ
drwxr-xr-x  2 mktips mktips 4096 Jun 17 data
```]

A routed cell. The trigger splits at `%`: the route `mktips@university-base` is
live markup (so `@university-base` resolves against the host db), and the command
is an inline-raw span (so its specials stay inert):

// mktips@university-base% grep -c '$' /etc/passwd
#cell(cmd: "grep -c '$' /etc/passwd", host: "mktips@university-base", cwd: "/home/mktips", code: 1)[```
0
```]

And the same prose can cite a host outside any cell — @simurgh-base resolves too,
while @nonexistent-box degrades to a legible marker instead of breaking the build.
