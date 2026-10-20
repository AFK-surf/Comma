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

The inspector UI portals to `document.body` and identifies itself as a React
Aria top-layer node, so app popovers and modal isolation do not block it.

## Configure overlay values

Pending edits live in the **Changes** card. Use it to review or clear edits, or
use **Clear all** and **Copy prompt**. **Copy source** in the selected-element
header copies the source location and DOM clues without making layout edits.
Drag the lower-right handle to resize the panel. Double-click the handle to
return to the content-sized panel.

The settings button in the selected-element header switches overlay labels
between **Pixels** (`12px`, the default) and **Variables** (`--spacing-lg`).
When a variable cannot be resolved, Variables shows the computed pixel value.
Hosts can choose a different initial mode and layer visibility:

```tsx
<LayoutInspector
  defaultOverlayVisibility={{ border: true }}
  defaultValueDisplayMode="variables"
/>
```

Padding, border, and gap each have an independent setting. Padding and gap
overlays are visible by default. Border overlays are opt-in.

Variable previews are temporary inline `!important` declarations. Hiding the
inspector keeps previews and pending changes. Only the Clear and Reset actions
remove them. On cleanup, the inspector restores a declaration only while it
still owns the exact value it installed, so it never overwrites a newer host
update. If a pinned node is detached or loses measurable geometry, the
inspector releases it and restores its previews.

## Include source file and line numbers

Add the optional Vite adapter before React. It injects relative source metadata
into native JSX elements during development, so copied prompts and pending
changes point to locations such as
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
for an internal static Storybook build. The adapter writes source paths into
the DOM, so do not enable it for a public production application.

The default variable resolver finds relevant CSS custom properties on the
selected element. Hosts with other token naming conventions can pass
`resolveVariables`:

```tsx
<LayoutInspector
  resolveVariables={({ property }) =>
    property.startsWith("border-")
      ? [{ label: "--stroke-thin · 1px", value: "--stroke-thin" }]
      : [{ label: "--space-4 · 16px", value: "--space-4" }]
  }
/>
```

## Limits

Authored-value lookup is conservative. When the inspector cannot prove which
declaration wins, it shows the computed value instead of a guessed authored
variable. See `src/authored-values.ts`.

Box-model and gap overlays are not drawn for transformed coordinate spaces and
some flex and grid cases. The overlay badge and Box model panel then show
**Limited geometry** with the reason. Dimensions and editable computed
properties stay available.

Copied prompts prefer injected source locations, then stable attributes, the
class sequence, nearby DOM context, and a runtime locator. React-generated IDs
are omitted.
