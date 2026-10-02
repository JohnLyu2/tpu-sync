// Minimal slide theme. No slide package: only page setup, a `slide` function
// and a few boxes, so the deck builds with a bare typst install.

#let accent = rgb("#1f4e79")
#let muted = rgb("#6b6b6b")
#let codebg = rgb("#f4f4f4")
#let warnbg = rgb("#fff7e6")

#let deck(title: none, short: none, body) = {
  set page(
    paper: "presentation-16-9",
    margin: (x: 1.2cm, top: 0.9cm, bottom: 0.9cm),
    footer: context [
      #set text(size: 10pt, fill: muted)
      #short
      #h(1fr)
      #counter(page).display()
    ],
  )
  set text(font: "Roboto", size: 14.5pt)
  set par(leading: 0.6em, justify: false)
  set list(marker: ([•], [–]), indent: 0.4em, body-indent: 0.5em)
  set enum(indent: 0.4em, body-indent: 0.5em)
  // Inline code (`in_flight_` etc.) deliberately a bit larger than body text:
  // identifiers must stay legible from the back of the room.
  show raw: set text(font: "DejaVu Sans Mono")
  show raw.where(block: false): set text(size: 1.05em)
  show raw.where(block: true): it => block(
    width: 100%, fill: codebg, inset: 9pt, radius: 3pt,
    text(size: 12pt, it),
  )
  show heading.where(level: 1): it => block(below: 0.8em)[
    #set text(size: 23pt, weight: "medium", fill: accent)
    #it.body
  ]
  show heading.where(level: 2): it => block(above: 0.8em, below: 0.4em)[
    #set text(size: 17pt, weight: "medium", fill: accent)
    #it.body
  ]
  show table: set text(size: 13.5pt)
  set table(
    stroke: (x, y) => if y == 0 { (bottom: 0.7pt + muted) } else { (bottom: 0.3pt + luma(210)) },
    inset: (x: 8pt, y: 6pt),
  )
  show table.cell.where(y: 0): set text(weight: "medium")
  body
}

#let slide(title, body, size: none) = {
  pagebreak(weak: true)
  heading(level: 1, title)
  context [#metadata(here().page()) <slidepage>]
  if size == none { body } else { text(size: size, body) }
}

#let title-slide(title, subtitle: none, meta: none) = {
  pagebreak(weak: true)
  v(1fr)
  text(size: 32pt, weight: "medium", fill: accent, title)
  if subtitle != none { v(0.6em); text(size: 19pt, subtitle) }
  v(1fr)
  if meta != none { text(size: 12pt, fill: muted, meta) }
  v(0.5em)
}

#let note(body) = text(size: 11.5pt, fill: muted, body)

#let callout(body, fill: warnbg) = block(
  width: 100%, fill: fill, inset: 9pt, radius: 3pt,
  text(size: 13.5pt, body),
)

#let small(body) = text(size: 12pt, body)

#let cols(..args) = grid(columns: args.named().at("columns", default: (1fr, 1fr)), column-gutter: 1.2em, ..args.pos())
