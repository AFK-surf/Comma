# Side Chat Backdrop

This macOS-only Node-API addon installs the Side Chat backdrop inside the
Electron `BrowserWindow`'s native content view. It owns visual composition
only: renderer code, chat state, and input never cross into this addon.

The implementation deliberately targets the previous native Side Chat visual
floor with the following algorithmic pieces:

- dynamically-created `CABackdropLayer`;
- dynamic `CAFilter` `gaussianBlur` with radius `24` and normalized edges;
- window-server-aware backdrop sampling;
- a four-edge smoothstep feather mask, solid outsets, gamma, alpha,
  pixel cap, and geometry-keyed mask cache;
- explicit layer rebuild and reveal-offset updates with Core Animation actions
  disabled;
- the previous host's `shouldAutoFlattenLayerTree = false` and
  `canHostLayersInWindowServer` false-to-true refresh on the real
  `ElectronNSWindow`, followed by `orderFrontRegardless()` /
  `displayIfNeeded()` recovery;
- one Core Animation transaction that moves the backdrop and every Chromium
  content sibling by the same reveal offset, including after resize,
  navigation, or renderer replacement;
- local and global mouse-move/drag monitors that make the feather-only region
  click-through while restoring input as soon as the pointer enters visible
  Side Chat content;
- active-Space and screen-parameter observers that rebuild the private backdrop
  immediately and once more 360ms later, preventing stale or blank WindowServer
  sampling after display topology changes.

`CommaSideChatBackdropView` subclasses `NSVisualEffectView` only so Chromium keeps
the host below its compositor surfaces during native-child reordering. AppKit's
public `maskImage` property uses a transparent image to hide its own material.
The custom `CABackdropLayer` and a separate tint layer live in a child view,
which the material mask does not affect. The addon captures all
pre-existing direct Chromium siblings rather than assuming one compositor view,
refreshes their base frames when Electron relayouts or replaces them, and
restores those frames on detach.

`CABackdropLayer` and `CAFilter` are private macOS implementation classes. All
class and selector access is checked dynamically. Material suppression uses the
public mask API instead of a private AppKit selector. `attach()` returns `false`
when either the masked backdrop or AppKit-material suppression is unavailable.
Electron Main then hides the Side Chat BrowserWindow and asks the presentation
owner to close it. This fail-closed behavior prevents an interactive rectangular
or blur-free window from silently shipping below the product's visual floor.

The Main-owned Debug tab is one explicit diagnostic escape hatch, matching the
former native settings scene: an operator may deliberately set
`showBackdrop=false`, `blurRadius=0`, or `maxMaskAlpha=0` while tuning. Those
accepted values are not treated as an unexpected native failure. They live only
for the current Main process; Reset or restarting Comma restores the protected
defaults. Outside that explicit Debug action, attach, mutation, health, and
post-attach failures remain fail-closed.

In the source dev app, **View > Side Chat Background…** selects the backdrop
panel in Runtime Workbench. **Window > Open Side Chat** opens the preview.
The panel sends at most one
update at a time and merges pending slider changes. It subscribes to owner
snapshots without polling. Packaged apps do not expose this menu or dev route.

The panel changes these Main-owned values while Side Chat is open.
Black tint opacity defaults to `0.06`. A normalized feather image controls
the opacity of the combined blur and tint. Zero blur radius
does not guarantee transparent sampled output. The common container mask makes
the whole effect transparent at its outer edges, including substitute color.
Tint has no additional mask. The common mask follows the same reveal offset as
the blur and tint layers. `maxMaskAlpha` controls the opacity of the combined
effect without changing the feather image. Tint updates change the existing
tint layer color.
Blur radius changes rebuild the filter. Mask gamma defaults to `1.25`.
Bottom feather defaults to `26`. Its content offset keeps the input at
its existing screen position.
Each fade keeps its configured width inside the window. If a content offset
would put a fade outside the window, its outer edge stops at the window edge
and its inner edge moves toward the content. This also applies to the left and
bottom edges when the host extends to the screen boundary.

## Main-process API

Load `comma-side-chat-backdrop.node` only in Electron Main. The handle passed to
`attach` is the buffer returned by `BrowserWindow.getNativeWindowHandle()`.

```ts
const { revision: _revision, ...visualSettings } = defaultSideChatDebugSettings;
backdrop.updateSettings(visualSettings);
backdrop.attach(window.getNativeWindowHandle()); // boolean
backdrop.isAvailable(); // false means Main must fail closed
backdrop.updateGeometry({
  windowWidth: 523,
  windowHeight: 412,
  contentX: 5,
  contentY: -9,
  contentWidth: 364,
  contentHeight: 286,
  visualWidth: 364,
  visualHeight: 286,
}); // boolean; false means Main must fail closed
backdrop.setRevealOffset(0); // boolean; false means Main must fail closed
backdrop.isIgnoringMouseEvents(); // Main-process diagnostic
backdrop.maximumRevealAlignmentError(); // 0 when renderer/backdrop are aligned
backdrop.isOrderedBelowContentSurfaces(); // true when native z-order is valid
backdrop.rebuild();
backdrop.rebuildRevision(); // Main-process smoke-test diagnostic
backdrop.detach();
```

Every AppKit/Core Animation mutation is synchronized onto the main thread. The
native view is inserted below Chromium's content surfaces and remains inside the
same `NSWindow`; the BrowserWindow must be transparent. Reveal movement is
native-owned: renderer presentation state remains available for phase/layout,
but renderer CSS must not apply a second horizontal translation.

Geometry uses the unflipped AppKit-local coordinate system. In particular,
`contentY` is the content bottom edge measured from the window bottom edge
(`contentFrame.y - windowFrame.y`), not Electron's top-left screen coordinate.

The renderer reports `sideChat.setContentSize.height` as window reserve and
`visualHeight` from the same height used to render `SideChatSurface`. Main passes
only the reserve to the gesture helper; it applies visible-only changes to the
backdrop immediately, without waiting for a changed helper frame. The visual
height is clamped to the available content frame. Omitting `visualHeight` means
no separate reserve. The native lifecycle regression checks the opacity mask,
rendered tint, parameter updates, and reveal alignment. It also renders
an opaque sample through the real layer tree to verify transparent outer edges
and a graduated fade. It does not verify WindowServer's final desktop blur.
Check that output over desktop content;
isolated window captures can return a substitute color. The former
`side_chat_geometry` TLA model is retired.

Mouse hit testing uses the current visual content frame plus reveal offset,
expanded by 2 points and clipped to the native window. A fully closed/revealed-
offscreen panel therefore always ignores mouse events. `detach()` removes both
event monitors and restores `NSWindow.ignoresMouseEvents` to `false`.

`rebuild()` uses the same two-stage WindowServer recovery as the lifecycle
observers: one synchronous rebuild and one generation-checked rebuild after
360ms. Rapid notifications replace the pending delayed rebuild. `detach()`
removes both observers and invalidates any delayed callback before removing the
native view.

The Electron native build copies the compiled binary to
`dist/native/macos/comma-side-chat-backdrop.node`, which Forge already packages
outside ASAR through the existing `dist/native` extra resource.
