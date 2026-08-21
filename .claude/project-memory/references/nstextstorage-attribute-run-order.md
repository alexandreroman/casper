---
name: "NSTextStorage attribute writes must go in ascending offset order"
description: "Attributes live in a run-length array, so writing them out of document order is quadratic and freezes the main thread"
type: reference
---

# NSTextStorage attribute writes must go in ascending offset order

`NSTextStorage` keeps its attributes in a run-length array
(`NSMutableRLEArray`). Inserting a run in the middle memmoves every run after
it, so the cost of a batch of attribute writes depends on the order they are
issued in:

- **Ascending offsets only ever append** — linear in the number of runs written.
- **Arbitrary offsets are quadratic** in the storage's total run count.

The diff renderer writes one `.foregroundColor` run per syntax run, tens of
thousands of runs for a large diff, which puts this squarely in freeze
territory. Measured with a harness reproducing
`DiffTextAssembly.applyHighlight`'s loop over one shared storage:

| files | total runs | ascending | arbitrary |
|-------|-----------:|----------:|----------:|
| 8     |    115 200 |    0.03 s |    0.75 s |
| 16    |    230 400 |    0.05 s |    2.98 s |
| 32    |    460 800 |    0.10 s |   12.11 s |
| 64    |    921 600 |    0.21 s |   51.77 s |

Ascending order holds flat at 0.23 µs per run; arbitrary order quadruples per
doubling of the file count. The symptom is the main thread spinning at ~100%
with no crash report, `sample` showing ~98% of samples in `_platform_memmove`
under `-[NSMutableRLEArray insertObject:range:]`.

`[String: DiffFileHighlight]` is the shape a highlight cache has, and iterating
it yields hash order — arbitrary by construction. Painting therefore walks
`DiffDocument.files` and looks each file's highlight up
(`DiffRendering.highlightsInDocumentOrder`), which is monotonic by construction
and needs no sort. That ordering is unobservable in the finished storage
(`applyHighlight` is idempotent and its output order-independent), so the
accessor exists as a pure seam a test can assert ascending indices on —
`DiffTextSurfaceTests.testCarriedHighlightsArePaintedInDocumentOrder`.
