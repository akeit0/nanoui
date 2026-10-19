# Font fallback and the reference frameworks

nanoui follows mygo and GPUI's rule that fallback text retains the original
run's weight and style. The text engines differ, so this is behavioral
alignment rather than a replacement of nanoui's portable TrueType engine.

References inspected for this change:

- [mygo's Windows text formats](https://github.com/egoist/mygo/blob/3d5c0df8105dbc508192d85b5376cf1de517902e/internal/text/dwrite_windows.go#L515)
  pass weight, italic style and locale to DirectWrite. Explicit fallback
  families precede system fallback. Format/face caches include their style.
- [GPUI's Cosmic Text backend](https://github.com/zed-industries/zed/blob/1f32ec0ceafddd6a368db8aef9d169a6569a1c23/crates/gpui_wgpu/src/cosmic_text_system.rs#L74)
  carries weight and style in fallback attributes. Its face matcher
  penalizes a style mismatch by 1000, then adds the weight difference.
- [GPUI PR #56771](https://github.com/zed-industries/zed/pull/56771)
  fixed weight/style being lost when initializing fallback fonts on macOS.

The portable backend previously cached fallback by code point alone and
returned the first loaded or discovered face containing the character.
On the development Windows machine, regular Japanese text consequently
selected `BIZ-UDGothicB.ttc` (700), although `BIZ-UDGothicR.ttc` (400) was
installed. The family scan order and prior bold text could change the result.

The corrected selection keeps preferred fallback families in their existing
order, matching the requested weight and italic style within each family.
For the remaining system candidates, it applies GPUI's style/weight score
before checking glyph coverage. Already-loaded faces have no extra priority.
Sibling faces are checked and there is no arbitrary 48-font cutoff. Cache
keys contain code point, weight and italic style, and adding a font clears
cached fallback choices. Allocation failure is not cached as missing coverage.

This fixes style selection for all scripts without forcing Japanese text
to use a single hardcoded family. It does not introduce DirectWrite/Cosmic
Text shaping, OS locale-based family selection, or grapheme-cluster shaping.
Those remain separate platform/text-system work.

Two regression tests cover this bug: controlled face metadata checks
selection and cache isolation across Regular, Bold and Italic; one Windows
integration test checks those attributes on shaped Japanese text. The first
reuses the same basic system fonts as the existing TrueType tests. The
Windows case checks only three known font files, never scans the whole
system, and skips when its Japanese fonts are unavailable.
