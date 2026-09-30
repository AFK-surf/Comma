# NotchKit

`NotchKit` is a local Swift package for building and running a macOS notch surface.

It is designed around one rule:

- The package owns notch-specific runtime behavior.
- The host app injects business data and SwiftUI content.

That means `NotchKit` is responsible for window creation, screen selection, physical notch alignment, interaction handling, state transitions, sizing, and rendering. Your app should only map its own domain state into a `NotchScene`.

## What the package owns

- The notch window lifecycle
- Screen selection and hardware-notch detection
- Compact / notifying / expanded presentation state
- Click-to-expand and click-outside-to-close behavior
- Compact layout anchored to the physical notch center
- Expanded sizing from content and sizing policy
- SwiftUI rendering and package-local previews

## What the host app owns

- Deciding whether there is any activity to show
- Deciding when a "new activity" notification should fire
- Providing the compact leading / compact trailing slot views
- Providing the expanded header slots and expanded content view
- Business actions inside those views

## Runtime states

`NotchKit` currently supports four presentation states:

- `collapsed`: completely hidden
- `active`: compact notch is visible
- `notifying`: compact notch is visible and plays the notification bounce
- `expanded`: fully expanded

State transitions are derived from the injected `NotchScene` plus runtime interaction:

- `hasActivity == false` collapses the notch
- `hasActivity == true` makes the compact notch visible
- changing `notificationToken` triggers the notifying animation if the notch is active
- clicking the compact notch opens expanded mode
- clicking outside the expanded notch closes it back to compact mode

## Public API

### `NotchController`

`NotchController` is the runtime entry point.

```swift
@MainActor
let controller = NotchController(configuration: .init())

controller.start()
controller.update(scene: scene)
controller.open()
controller.close()
controller.toggle()
controller.stop()
```

Behavior notes:

- `start()` creates and begins managing the notch window.
- `update(scene:)` may be called before or after `start()`.
- `open()` is ignored when there is no activity.
- `close()` returns to `active` when activity still exists, otherwise `collapsed`.
- `toggle()` flips between compact and expanded when activity exists.

### `NotchScene`

`NotchScene` is the host-controlled snapshot injected into the runtime.

```swift
public struct NotchScene {
    public var hasActivity: Bool
    public var notificationToken: AnyHashable?
    public var compactLeadingSlot: AnyView
    public var compactTrailingSlot: AnyView
    public var expandedLeadingSlot: AnyView
    public var expandedTrailingSlot: AnyView
    public var expandedContent: AnyView
    public var expandedSizing: NotchExpandedSizing
}
```

Important semantics:

- `hasActivity`
  Controls whether the notch exists at all. `false` means fully collapsed.
- `notificationToken`
  Change this value when you want to play the "new activity" animation. Reusing the same value does nothing.
- `compactLeadingSlot` / `compactTrailingSlot`
  Compact-mode content on the left and right of the physical notch.
- `expandedLeadingSlot` / `expandedTrailingSlot`
  Header content on the left and right of the physical notch in expanded mode.
- `expandedContent`
  Main expanded body.
- `expandedSizing`
  Controls how expanded size is resolved.

Use `NotchScene.erased { ... }` to type-erase SwiftUI views into `AnyView`.

### `NotchExpandedSizing`

```swift
public enum NotchExpandedSizing {
    case intrinsic
    case clamped(min: CGSize, max: CGSize)
    case fixed(CGSize)
}
```

Use:

- `.intrinsic` when the content reports a stable natural size
- `.clamped` when you want content-driven sizing but within limits
- `.fixed` when the host wants a hard size, or when the content uses unbounded layouts such as `GeometryReader` / unconstrained scroll content

### `NotchConfiguration`

`NotchConfiguration` controls runtime behavior and visual constants.

Key options:

- `screenSelectionPolicy`
  - `.builtInFirst`
  - `.screenUnderPointer`
  - `.mainScreen`
- `fallbackNotchSize`
  Used when the selected screen has no hardware notch
- `compactContentInsets`
- `expandedPadding`
- `maximumExpandedSize`
- `minimumExpandedSize`
- `interactionOutset`
- `notificationScale`
- `notificationHoldDuration`
- `animation`
- `hapticFeedbackEnabled`

## Sizing model

### Compact width

Compact width is dynamic. The host does not provide a fixed compact width.

`NotchKit` measures both compact slots and computes:

```text
compact width =
    leading inset
  + leading slot width
  + hardware notch width
  + trailing slot width
  + trailing inset
```

The physical notch stays centered on the display notch. If the leading and trailing slots are asymmetric, the shell may extend farther to one side. This is intentional.

### Expanded size

Expanded size is resolved from:

- the selected `NotchExpandedSizing`
- the measured expanded content size
- the measured header slot widths
- package configuration min / max bounds

## Quick start

The usual integration pattern is:

1. Create one `NotchController`.
2. Start it during app boot.
3. Convert your domain state into `NotchScene`.
4. Call `update(scene:)` whenever that state changes.

Example:

```swift
import Combine
import NotchKit
import SwiftUI

@MainActor
final class MyNotchAdapter {
    private let controller = NotchController(
        configuration: .init(
            screenSelectionPolicy: .builtInFirst,
            maximumExpandedSize: CGSize(width: 640, height: 220),
            minimumExpandedSize: CGSize(width: 400, height: 140)
        )
    )

    private var cancellable: AnyCancellable?
    private var lastCount = 0
    private var notificationSequence = 0

    func start(store: TaskStore) {
        controller.start()

        cancellable = store.didChange
            .receive(on: RunLoop.main)
            .sink { [weak self, weak store] in
                guard let self, let store else { return }
                self.pushScene(from: store)
            }

        pushScene(from: store, notifyOnIncrease: false)
    }

    private func pushScene(from store: TaskStore, notifyOnIncrease: Bool = true) {
        let count = store.visibleTaskCount

        if notifyOnIncrease, count > lastCount {
            notificationSequence += 1
        }
        lastCount = count

        let scene: NotchScene
        if count == 0 {
            scene = .hidden
        } else {
            let compactSideWidth: CGFloat = 48

            scene = NotchScene(
                hasActivity: true,
                notificationToken: notificationSequence,
                compactSideWidth: compactSideWidth,
                compactLeadingSlot: NotchScene.erased {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.leading, 10)
                        .frame(width: compactSideWidth, alignment: .leading)
                        .clipped()
                },
                compactTrailingSlot: NotchScene.erased {
                    Text("\(count)")
                        .padding(.trailing, 10)
                        .frame(width: compactSideWidth, alignment: .trailing)
                        .clipped()
                },
                expandedLeadingSlot: NotchScene.erased {
                    Button("Inbox") {}
                },
                expandedTrailingSlot: NotchScene.erased {
                    Button("Settings") {}
                },
                expandedContent: NotchScene.erased {
                    TaskListView(store: store)
                },
                expandedSizing: .clamped(
                    min: CGSize(width: 420, height: 140),
                    max: CGSize(width: 720, height: 320)
                )
            )
        }

        controller.update(scene: scene)
    }
}
```

## Preview-driven development

`NotchKit` intentionally keeps the renderer usable outside the runtime window manager.

Use `NotchKitView` and `NotchKitModel` when you want to iterate on shell visuals, slot composition, and transitions in SwiftUI previews without spinning up the real notch window.

Example:

```swift
#Preview("Active") {
    NotchKitView(
        model: NotchKitModel(
            state: .active,
            layout: .init(
                deviceNotchSize: CGSize(width: 150, height: 28),
                compactSize: CGSize(width: 300, height: 28),
                expandedSize: CGSize(width: 620, height: 180)
            )
        )
    ) {
        Label("2 running", systemImage: "waveform.circle.fill")
            .padding(.leading, 8)
    } compactTrailing: {
        Text("3")
            .padding(.trailing, 8)
    } expandedLeading: {
        EmptyView()
    } expandedTrailing: {
        EmptyView()
    } expandedContent: {
        RoundedRectangle(cornerRadius: 18)
            .fill(.white.opacity(0.08))
            .frame(width: 560, height: 100)
    }
    .frame(width: 760, height: 320, alignment: .top)
    .preferredColorScheme(.dark)
}
```

Notes:

- `NotchKitView` is the renderer only. It does not create windows or manage interaction.
- Previews are best for visual iteration, not for validating real screen placement.
- The package already includes internal previews in `Sources/NotchKit/NotchKitView.swift`.

## Integration checklist

- Keep one long-lived `NotchController` per app session.
- Do not pass business view models into the package itself.
- Build a thin adapter that translates host state into `NotchScene`.
- Prefer `notificationToken` over direct imperative animation calls.
- Use `.fixed` expanded sizing if your content does not report a stable intrinsic size yet.
- Inject any required host environments inside the `NotchScene` views before erasing them.

## Window identification

If the host app needs to identify the notch window for automation or diagnostics, use:

```swift
NotchController.automationIdentifier
```

The runtime window uses this value as its `NSWindow.identifier`.

## Current interaction model

The current built-in interaction model is intentionally small:

- compact click opens expanded mode
- compact click while expanded closes the notch
- clicking outside expanded mode closes the notch

If you want more advanced interaction later, extend the package runtime instead of pushing notch-specific window logic back into the host app.

## Repository location

In this repository the package lives at:

```text
frontend/macos/Frameworks/NotchKit
```

It is linked into the macOS app as a local Swift package.
