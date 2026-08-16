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
| configuration and context | `#CC4E00` | `#FFDDA6` |
| state and policy | `#635DFF` | `#A7A6FF` |

Editable Draw.io sources mirror publication paths:

```text
doc/fig/wiki_src/<section>/<figure>.drawio
  -> doc/fig/wiki/<section>/<figure>.svg
```

`ARCHITECTURE.md` maps to the `01_architecture` figure section. The Draw.io
file owns editable geometry and text; the publication SVG is reviewed and
post-processed for live-text classes, compact markers, accessibility metadata,
and paired dark-theme rules. Preserve those SVG features after any re-export.
Within section `01`, filename `f01` publishes as Figure 1.1.

Normal blocks and connectors use 2 px strokes, emphasized routes use 3 px, and
outer boundaries use at most 4 px. Figures use Helvetica-compatible sans-serif
text, monospace identifiers, orthogonal routes, no gradients or shadows, and a
minimum 20 px source font on a 1600 px canvas.

## Figure register

| Figure | Visible title | Embedding page |
|---|---|---|
| [`01_architecture/architecture-f01-request-memory-paths.svg`](wiki/01_architecture/architecture-f01-request-memory-paths.svg) | Figure 1.1 — Request and memory paths | [`ARCHITECTURE.md`](../ARCHITECTURE.md) |
