# Figure sources

Published figures use live-text SVG with transparent canvases, paired light and
dark colors, compact arrowheads, and the following matte semantic fills:

| Role | Strong token | Matte fill |
|---|---|---|
| text and structure | `#3A414A` | `#F7F4E4` |
| block border | `#000000` → `#E7E2D9` in dark mode | — |
| rail and divider | `#979EA8` | — |
| request and data path | `#1071E5` | `#C1E4F7` |
| memory and control | `#008A0E` | `#D7FAF5` |
| terminal and invalidate | `#C92D39` | `#FFBBB1` |
| configuration and context | `#CC4E00` | `#FFDDA6` |
| state and policy | `#635DFF` | `#A7A6FF` |

Editable Draw.io sources mirror publication paths:

```text
doc/fig/wiki_src/<section>/<figure>.drawio
  -> doc/fig/wiki/<section>/<figure>.svg
```

Section `01_architecture` contains figures for both `ARCHITECTURE.md` and
`INTERFACING.md`; `fNN` is a section-wide counter, so filename `f05` publishes
as Figure 1.5. The Draw.io file owns editable geometry and wording; the
publication SVG owns the final sans/monospace role split and is post-processed
for live-text classes, compact markers, accessibility metadata, and paired
dark-theme rules. Preserve those SVG features after any re-export.

Normal blocks and connectors use 2 px strokes, emphasized routes use 3 px, and
outer boundaries use at most 4 px. Figures use Helvetica-compatible sans-serif
text, monospace identifiers, orthogonal routes, no gradients or shadows, and a
minimum 20 px source font on a 1600 px canvas.

Monospace rows are budgeted at approximately `0.62 em` per character; boxes
must be sized from monospace metrics rather than the proportional Draw.io
default.

## Figure register

| Figure | Visible title | Embedding page |
|---|---|---|
| [`01_architecture/architecture-f01-request-memory-paths.svg`](wiki/01_architecture/architecture-f01-request-memory-paths.svg) | Figure 1.1 — Request and memory paths | [`ARCHITECTURE.md`](../ARCHITECTURE.md) |
| [`01_architecture/architecture-f02-request-flows.svg`](wiki/01_architecture/architecture-f02-request-flows.svg) | Figure 1.2 — Request flows | [`ARCHITECTURE.md`](../ARCHITECTURE.md) |
| [`01_architecture/architecture-f03-pipeline-finish.svg`](wiki/01_architecture/architecture-f03-pipeline-finish.svg) | Figure 1.3 — Pipeline timing and finish serialization | [`ARCHITECTURE.md`](../ARCHITECTURE.md) |
| [`01_architecture/architecture-f04-narrow-shim-flow.svg`](wiki/01_architecture/architecture-f04-narrow-shim-flow.svg) | Figure 1.4 — Narrow-port adaptation | [`ARCHITECTURE.md`](../ARCHITECTURE.md) |
| [`01_architecture/interfacing-f05-axi-boundaries.svg`](wiki/01_architecture/interfacing-f05-axi-boundaries.svg) | Figure 1.5 — AXI boundary contract | [`INTERFACING.md`](../INTERFACING.md) |
