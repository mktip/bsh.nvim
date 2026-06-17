// bsh.nvim — Typst rendering for owned cells.
//
// A `% cmd` trigger line in a `.bsh.typ` buffer stays as your one-character
// prompt; on <CR> bsh writes the OWNED element below it as a `#cell(...)` call.
// Because that call carries the command and its run-context as STRUCTURED
// FIELDS (not free text), the template can typeset it into a card: the command
// becomes a header, the captured stdout becomes the body, and the route / cwd /
// exit code become the card's chrome. Re-running rewrites the call in place;
// it is plain buffer text, so it survives `:w` and needs no export pass.
//
//   #import "template.typ": cell, bsh
//   #show: bsh            // installs the styling
//
// then bsh-emitted blocks like
//
//   #cell(cmd: "ls -al", host: none, cwd: "~/pockt", code: 0)[
//   total 24
//   drwxr-xr-x  5 mktips mktips 4096 Jun 17 .
//   ...
//   ]
//
// render as the terminal card.

#let bsh-theme = (
  bg:     rgb("#1b1e24"),
  chrome: rgb("#262b33"),
  fg:     rgb("#d7dae0"),
  muted:  rgb("#7a828e"),
  prompt: rgb("#8fd96b"),  // the green `$`
  ok:     rgb("#8fd96b"),
  bad:    rgb("#e06c75"),
  host:   rgb("#61afef"),  // a resolved @host citation
)

// The route label, if there is one. No "Terminal" caption — it IS a terminal,
// it doesn't need to announce itself.
#let _cell-label(host) = if host == none { none } else { host }

#let cell(cmd: "", host: none, cwd: none, code: 0, body) = {
  let t = bsh-theme
  block(
    width: 100%,
    fill: t.bg,
    breakable: false,
    {
      // ── header strip: route · cwd (only if there's anything to say) ──
      let label = _cell-label(host)
      if label != none or cwd != none {
        block(
          width: 100%,
          fill: t.chrome,
          inset: (x: 12pt, y: 5pt),
          grid(
            columns: (auto, 1fr, auto),
            align: (left + horizon, center, right + horizon),
            if label != none { text(fill: t.muted, size: 8pt, weight: "medium", font: "DejaVu Sans Mono", label) },
            [],
            if cwd != none { text(fill: t.muted, size: 8pt, font: "DejaVu Sans Mono", cwd) },
          ),
        )
      }
      // ── body: the prompt line, then captured output ─────────────────
      block(
        width: 100%,
        inset: (x: 12pt, y: 10pt),
        text(font: "DejaVu Sans Mono", size: 9pt, fill: t.fg, {
          // the green `% cmd` (or a red one if it failed) — the prompt glyph
          // is display-only; it matches your sigil, it isn't a parsed token.
          text(fill: if code == 0 { t.prompt } else { t.bad }, weight: "bold")[% ]
          text(fill: t.fg)[#cmd]
          if code != 0 {
            h(1fr)
            text(fill: t.bad, size: 8pt)[exit #code]
          }
          linebreak()
          // the output, verbatim — `body` is content so newlines are preserved
          // when callers pass a raw block; for a plain string we render as-is.
          set text(fill: t.muted)
          body
        }),
      )
    },
  )
}

// One show-rule installer. Call `#show: bsh.with(hosts: hosts)` once at the top.
//
// `hosts` is the registry from `gen-hosts` (keyed by sys/dom/fqdn). It powers
// the @host citation: a route like `mktips@university-base%` leaves `@university
// -base` as a live Typst ref, and this rule resolves it — the text stays the
// name you typed (readable), but where the registry knows an IP the name becomes
// a clickable `ssh://<ip>` link, so the *reference target* is the address. An
// unknown host renders `?host` (still legible) instead of a hard compile error.
#let bsh(doc, hosts: (:)) = {
  set text(font: "DejaVu Sans", size: 10pt)
  set par(leading: 0.65em)
  show ref: it => {
    let key = str(it.target)
    if key in hosts {
      let h = hosts.at(key)
      let name = text(fill: bsh-theme.host, font: "DejaVu Sans Mono")[#("@" + key)]
      if "ip" in h { link("ssh://" + h.ip, name) } else { name }
    } else {
      text(fill: bsh-theme.bad, font: "DejaVu Sans Mono")[?#key]
    }
  }
  doc
}
