# Design System

## World

The talk dashboard uses an early one-bit desktop language: off-white paper,
near-black ink, one-pixel chrome, ordered dithers, and overlapping utility
windows. It is a technical operating surface, not a marketing dashboard.

## Tokens

- Ink: `#11110f`
- Paper: `#f7f7f2`
- Border: one solid ink pixel
- Display and data type: Monaco, Menlo, Consolas, Courier fallback
- Radius: none
- Depth: one stepped window shadow

## Structure

- The four-stage capability handoff owns the top rail.
- Topology, event tape, and selected peer form one non-overlapping desktop row.
- The command strip anchors the bottom and contains the only primary action.
- Below 760px, windows tile into document order and the pipeline becomes 2x2.

## States

- Pending: paper
- Active: inverted ink field
- Complete: diagonal one-bit dither
- Error: dense reverse dither
- Connection status always includes text, never color alone.

## Motion

Only the active stage dithers, using stepped timing. Reduced-motion users see a
static active field. No scroll or pointer animation is used.

## Accessibility

Body contrast exceeds WCAG AA. The run control has a visible double focus ring,
stage changes are announced through a live region, the event tape is a live log,
and the dashboard has no horizontal overflow at 390px.
