# NotchKit

`NotchKit` is a local Swift package that builds and runs a macOS notch surface. `NotchHost` (`../NotchHost`) links it as a local Swift package.

The package owns notch-specific runtime behavior. The host app injects business data and SwiftUI content as a `NotchScene`.

## What the package owns

- The notch window lifecycle
- Screen selection and hardware-notch detection
- Compact, notifying and expanded presentation state
- Click-to-expand and click-outside-to-close behavior
- Compact layout anchored to the physical notch center
- Expanded sizing from content and sizing policy
- SwiftUI rendering and package-local previews

## What the host app owns

- Whether there is any activity to show
- When a "new activity" notification fires
- The compact leading and trailing slot views
- The expanded header slots and expanded content view
- Business actions inside those views

## Runtime states

- `collapsed`: hidden
- `active`: compact notch is visible
- `notifying`: compact notch plays the notification bounce
- `expanded`: fully expanded

Transitions:

- `hasActivity == false` collapses the notch. `true` shows the compact notch.
- A new `notificationToken` value plays the notifying animation if the notch is active. The same value does nothing.
- A click on the compact notch opens expanded mode. A click on it while expanded, or a click outside, closes it.

## Public API

The public types are in `Sources/NotchKit/`:

- `NotchController`: the runtime entry point (`start`, `update(scene:)`, `open`, `close`, `toggle`, `pulse`, `stop`). `update(scene:)` works before or after `start()`. `open()` is ignored when there is no activity. `close()` returns to `active` when activity exists, otherwise to `collapsed`.
- `NotchScene`: the host snapshot. Use `NotchScene.erased { ... }` to type-erase SwiftUI views and `NotchScene.hidden` for no activity.
- `NotchExpandedSizing`: `.intrinsic` for content with a stable natural size, `.clamped(min:max:)` for content-driven size within limits, `.fixed` for a hard size or for unbounded layouts such as `GeometryReader` or unconstrained scroll content.
- `NotchConfiguration`: screen selection policy, insets, size bounds, animations and haptics.
- `NotchKitView` and `NotchKitModel`: the renderer only, for SwiftUI previews. It does not create windows or handle interaction. See the previews in `NotchKitView.swift`.

## Sizing

Compact width is the sum of the compact content insets, the leading slot width, the hardware notch width and the trailing slot width. The slot widths come from the scene (`compactSideWidth`, or `compactLeadingWidth` and `compactTrailingWidth`). The physical notch stays centered on the display notch, so asymmetric slots extend the shell farther to one side.

Expanded size comes from the `NotchExpandedSizing` value, the measured content and header slot sizes, and the configuration min and max bounds.

## Integration rules

- Keep one long-lived `NotchController` per app session.
- Do not pass business view models into the package.
- Build a thin adapter that converts host state into `NotchScene` and calls `update(scene:)` when that state changes.
- Use `notificationToken` instead of direct animation calls.
- Use `.fixed` expanded sizing if your content does not report a stable intrinsic size.
- Inject required host environments inside the `NotchScene` views before you erase them.
- Add new interaction to the package runtime. Do not put notch-specific window logic in the host app.

## Window identification

For automation or diagnostics, the notch window uses `NotchController.automationIdentifier` as its `NSWindow.identifier`.
