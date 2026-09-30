# Comma UI Package Guide

Figma source: `VnkgBb2xCr5bRp4KHrLrqs` ([Comma Design System](https://www.figma.com/design/VnkgBb2xCr5bRp4KHrLrqs/Comma-Design-System)).

Icons use **Central Icons** npm packages (`@central-icons-react/...`), not exported SVGs. Record each icon in `src/components/icons/iconRegistry.ts` with a real Figma node id when it comes from Figma, plus its Figma name, variant, and npm import. If an implementation-only icon has no Figma node yet, mark it as `source: "central"` instead of inventing a placeholder node id. Helpers live in `centralIconVariants.ts`.

## Get the icon name

1. Call Figma MCP `get_design_context` on the icon instance node or a small composed instance, for example sidebar `7601:14308`. Do not pull whole pages; they time out.
2. Read the instance `data-name`:
   - Glyph name examples: `magnifying-glass, search`, `box-2, inbox, archive, tray, shelf`, `chevron-down-small`. Use the leading phrase and map it to npm `IconXxx`, for example `magnifying-glass, search` becomes `IconMagnifyingGlass`. Confirm the file exists under `@central-icons-react/round-{outlined|filled}-radius-{1|2}-stroke-2`.
   - Comma client interface glyphs use Central Icons stroke `2`. For example, `filled=off, stroke=2, radius=2, join=round` maps to `@central-icons-react/round-outlined-radius-2-stroke-2`.
3. Wire `src/components/icons/iconRegistry.ts`, then import in `src/components/icons/index.tsx` or the component-local icon entrypoint.
4. Run `pnpm exec vitest run packages/ui/src/components/icons`.

Use `createCentralIcon` for interface glyphs. The global rendered stroke width lives in `src/tokens/icons.ts` as `iconStrokeWidth` and is emitted as `--comma-icon-stroke-width` for every UI surface. Icon instances do not accept a `strokeWidth` override. The wrapper applies the shared accessibility contract and the `data-comma-icon` marker; shared CSS fixes icon geometry independently of the appearance font-size preference and disables icon-level scaling while leaving control hit targets unchanged. Use `comma-icon-slot` on a wrapper when its child SVG fills the slot, so the wrapper's numeric `size-*` utility stays on the same fixed pixel basis. The shared CSS maps the nominal `stroke-width="2"` paths from that one global token; Central's smaller optical sub-strokes remain fixed in their upstream SVG paths. `BookIcon`, `PanelLeftIcon`, and `PanelRightIcon` are explicit fill-only silhouette exceptions: their full geometry remains fixed with the preference, but they have no SVG stroke to adjust.

Do not guess icon names from UI labels, for example Search does not imply `IconQuickSearch`. Do not assume one global radius/fill variant. The client interface package variant uses stroke `2`; individual glyph geometry may still contain optical sub-strokes or fill-only silhouettes.
