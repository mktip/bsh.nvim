#import "template.typ": cell, bsh
#import "hosts.typ": hosts
#show: bsh.with(hosts: hosts)

= Every cell kind, carded

A shell `%` cell — the structured `#cell` with chrome:

#cell(cmd: "ls -al", host: none, cwd: "~/pockt", code: 0)[```
total 24
drwxr-xr-x  5 mktips mktips 4096 Jun 18 .
-rw-r--r--  1 mktips mktips  812 Jun 18 README.md
drwxr-xr-x  2 mktips mktips 4096 Jun 18 data
```]

A `:` listing — directories in accent, `../` muted:

: ~/pockt
```dir
../
bsh.nvim/
dots/
notes.md
todo.txt
```

A namespace menu (`docker.conn`), drillable in the editor:

docker.conn
```menu
web-1
db-1
cache-1
```

The agent friend (`>>` folds in one preceding cell):

>> summarise what just ran
```agent
The listing shows a pockt directory holding the bsh.nvim repo, your dotfiles,
and a couple of loose notes.

Nothing looks out of place; todo.txt is the only file you might want to act on.
```
