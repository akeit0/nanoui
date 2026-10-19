# Windows CPU renderer

First optimization pass in this fork, measured headlessly on the same
Windows x86-64 machine with Zig 0.17.0, ReleaseFast, 900×640 logical pixels
at 150% scale, 10 warm-up frames and 30 measured frames, best of two repeats.
Raw runs, including an intermediate change, are in
[history-cpu.jsonl](../history-cpu.jsonl).

| Scene | Before, median ms | After, median ms | Reduction |
|---|---:|---:|---:|
| 600 moving shadowed boxes | 40.776 | 38.842 | 4.7% |
| 300 changing text labels | 5.234 | 3.056 | 41.6% |
| 1000 scrolling rows | 4.349 | 2.229 | 48.7% |
| 100 000-row virtual list | 3.948 | 1.854 | 53.0% |
| Dashboard with 12 cards | 27.307 | 5.549 | 79.7% |

Numbers include view building, layout, paint, rasterization and allocating
and freeing the offscreen framebuffer. They exclude live GDI presentation
and Windows scheduling; they are not observed FPS. Differences below 5%
are treated as noise. Use longer runs before drawing conclusions about
small changes, and expect different absolute numbers on other machines.

Reproduce from `hillclimb/`:

```powershell
zig build run -j1 -- --frames 30 --repeat 2 --scale 1.5 --label "change"
```

The renderer fills opaque interiors as spans, retaining the scalar path
for edges, borders, transparency and rounded clips. Gaussian integration
samples are calculated once per row. Repeated shadow geometry caches its
uncolored floating-point coverage; color and rounded clipping are still
applied during compositing. Cache keys include position, dimensions,
radius, blur, DPI and visible bounds. Each surface has up to 64 entries
and a 16 MiB pixel budget; new shapes must recur before allocating masks.
Allocation failure, oversized shadows and moving geometry fall back to
uncached drawing. Nothing polls or adds idle work.

Tests compare optimized spans and shadow samples with the scalar formulas,
and compare cached/uncached pixels through movement, resizing, fractional
DPI, color and clip changes. Cache eviction and the memory bound are tested.

Future Windows work should measure dirty-region rendering, animation
pacing, per-monitor DPI behavior, IME, accessibility and a GPU backend.
Those capabilities are not implemented by this rendering change.
