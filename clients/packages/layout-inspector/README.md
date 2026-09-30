# `@comma/layout-inspector`

An opt-in React layout debugger for inspecting and previewing box-model CSS
variables. Nothing is mounted automatically.

## Mount it

```tsx
import { LayoutInspector } from "@comma/layout-inspector";

export function DevTools() {
  return import.meta.env.DEV ? <LayoutInspector /> : null;
}
```

Press <kbd>Command</kbd>/<kbd>Control</kbd> + <kbd>Shift</kbd> + <kbd>L</kbd> to
toggle the inspector. Pass `defaultActive` when a host, such as Storybook,
already has its own enable/disable control.

The inspector UI portals directly to `document.body` so application stacking
contexts cannot place app-level popovers above its interactive panel. It also
identifies itself as a React Aria top-layer node so modal overlay isolation does
not make the debugger inert while a menu remains open.

## Configure overlay values

The panel keeps **Box model** first and gives the scrollable **Properties**
section a stable minimum height. Pending edits live in the compact **Changes**
card at the bottom; open the card to review or clear individual edits, or use
its direct **Clear all** and **Copy prompt** actions.

Use **Copy source** in the selected-element header to copy its source file,
line and column, best-effort runtime locator, stable attributes, full class
sequence, and nearby DOM context without making any layout edits. If the element
has no injected source metadata, the report explicitly says the source location
is unavailable and includes the DOM clues instead. This action is independent
of **Copy prompt** and does not change pending edits.

Drag the lower-right handle to resize the panel. Its minimum height is derived
from the fixed header, Box model, Changes card, and the Properties minimum, so
resizing cannot squeeze Properties below its usable scroll area. Double-click
the handle to return to the content-sized panel.

Open the settings button in the selected-element header to switch overlay labels
between:

- **Pixels** — `12px`
- **Variables** — `--spacing-lg`

`Pixels` is the default. When a source variable cannot be resolved, Variables
falls back to the computed pixel value so the overlay never loses the
measurement. Hosts can choose a different initial mode and layer visibility:

```tsx
<LayoutInspector
  defaultOverlayVisibility={{ border: true }}
  defaultValueDisplayMode="variables"
/>
```

Padding, border, and gap each have an independent setting. Padding and gap
overlays are visible by default, while border overlays are opt-in; margin
remains visible as the outer box-model reference.

Variable previews are temporary inline `!important` declarations. Hiding or
deactivating the inspector preserves previews and pending changes; reopening it
restores the same working state so changes are removed only through the panel's
Clear/Reset actions. Invalid-target and unmount cleanup still restore the
previous declaration only while the inspector owns the exact value it installed,
so a newer host/React inline update is never overwritten. Relevant CSS
transitions are suppressed for preview and owned restore writes so measurement,
overlay, copied pending values, and the hidden page all describe the settled
layout.

Pinned targets are also lifecycle-bound. If the selected node is detached,
becomes `display: none`/`display: contents`, or otherwise loses measurable
geometry, the inspector releases it immediately and restores any preview values
it still owns instead of editing a stale DOM node. While pinned, external DOM
tree, attribute, and text mutations are coalesced to at most one measurement
per animation frame so the overlay also follows position-only reflows around
the target. Inspector-owned mutations are excluded, and queued work is
suspended immediately on release or deactivation without clearing pending
changes, then canceled on cleanup. A
bounded `ResizeObserver` set follows the target, its ancestor chain, and the
nearest surrounding elements (up to 128 total) so intrinsic growth and
mutation-free layout animations also trigger reconciliation without polling.

## Include source file and line numbers

Add the optional Vite adapter before React. It injects relative source metadata
into native JSX elements during development, allowing copied prompts and
pending changes to point directly to locations such as
`clients/packages/ui/src/components/left-rail/LeftRail.tsx:140:5`.

```ts
import react from "@vitejs/plugin-react";
import { resolve } from "node:path";
import { defineConfig } from "vite";
import { layoutInspectorSourcePlugin } from "@comma/layout-inspector/vite";

export default defineConfig({
  plugins: [
    layoutInspectorSourcePlugin({
      root: resolve(import.meta.dirname, "../../.."),
    }),
    react(),
  ],
});
```

The adapter is disabled in Vite production mode by default. Set `enabled: true`
for an internal static Storybook build. Because source paths are emitted into
the DOM, do not enable it for a public production application.

The default variable resolver discovers relevant CSS custom properties from the
selected element. Hosts with different token naming conventions can pass
`resolveVariables`.

```tsx
<LayoutInspector
  resolveVariables={({ property }) =>
    property.startsWith("border-")
      ? [{ label: "--stroke-thin · 1px", value: "--stroke-thin" }]
      : [{ label: "--space-4 · 16px", value: "--space-4" }]
  }
/>
```

Authored-value lookup traverses accessible, active CSSOM rules once per
selection. Disabled stylesheets and sheets whose own media is inactive are
skipped; unknown sheet activity remains an ambiguity marker. Distinct rules
remain distinct competitors even when their selectors and expressions are
identical. Only duplicate CSSOM longhand/shorthand views inside the same
declaration block are collapsed. A variable-bearing declaration is reported as
authored only when it is the sole matched declaration, its variables resolve,
and a source-property probe resolves to the browser's computed longhand. A sole
inline declaration may also be retained when its variables can be safely
substituted and the resulting source-property value is valid. The only bounded
multi-declaration exception is box spacing: one matching variable declaration
may be retained for margin/padding/gap when every other matched declaration
resolves to a fixed absolute pixel value that does not match. Width, height,
border, contextual values, and otherwise uncertain competition conservatively
use the computed value because the detached probe cannot reproduce the browser's
full cascade and layout context. An active animation or transition affecting an
inspected property also forces computed provenance because the animation
cascade sits above author declarations. Matching declarations inside element-
or lifecycle-dependent rule groups that CSSOM
cannot safely evaluate, such as `@container`, `@scope`, and
`@starting-style`, remain ambiguity markers instead of being discarded; they
therefore prevent a lower declaration from being presented as authored.
Accessible imports, shadow-root stylesheets, CSS Nesting rules, and nested
declaration blocks participate in the same collection, and imports retain the
originating stylesheet's implicit scope root. Expressions are probed on the
property where they were declared before reading the inspected longhand, so
shorthand values and property-specific keywords are not tested as unrelated
widths. Declarations below every unresolved CSS Nesting boundary remain
property-locally ambiguous. Parent-selector presence is not used to prune them:
contextual nested selectors can apply precisely when their outer selector has
no matching element. If any applicable stylesheet is CSSOM-inaccessible,
authored and inferred provenance are disabled rather than guessing past an
opaque winner. Cross-tree sources use the same conservative boundary: an
accessible assigned-slot root, an open shadow root owned by the selected host,
and accessible outer roots for `part`/`exportparts` are scanned with their own
stylesheet ownership. Because standard selector APIs cannot match
`::slotted()`, `:host`, or `::part()` against the selected element, declarations
from those roots remain property-local ambiguous competitors rather than being
parsed into a guessed cross-shadow cascade. Cross-root traversal is capped at 32
stylesheet roots; exceeding the cap disables authored/inferred provenance.
Closed slot assignment is not exposed by the platform (`assignedSlot` is null),
so closed-root `::slotted()` provenance remains outside this accessible-CSSOM
contract.
Percentage and `calc()` gaps are resolved against the selected element's used
content-box geometry, with flex values bounded by actual item and line
separation before their overlays are drawn.

Geometry overlays intentionally have a bounded support contract. The inspector
draws precise box-model and gap regions for elements outside transformed
coordinate spaces and ordinary direct element flex/grid items. A non-`none`
`transform` or `perspective`, or a non-identity individual `translate`,
`rotate`, or `scale` on the target or an ancestor, omits all box-model regions.
Flex layouts containing `display: contents` children or non-collapsible direct
text that creates anonymous flex items, and grids with collapsed auto-fit
tracks, keep their box-model regions but omit gap regions. The overlay badge and
Box model panel show **Limited geometry** with the reason in each case;
dimensions and editable computed properties remain available.

Copied prompts prioritize injected source locations, then fall back to stable
attributes, the complete class sequence, nearby DOM context, and a best-effort
runtime locator. React-generated IDs are omitted. Matched CSS selectors are
reported only as lookup clues, and shared utility rules are explicitly
distinguished from the component source that uses them.
