# Settings

## Ownership

`@comma/ui` owns the complete settings surface: navigation, category icons,
search, empty states, setting rows, and controls. Product clients provide a
localized registry plus values and callbacks. They must not rebuild settings
markup or styling.

## Registry shape

Create one registry with `createSettingsRegistry`:

```tsx
const registry = createSettingsRegistry({
  groups: [
    {
      id: "application",
      label: "Application",
      categories: [
        {
          id: "general",
          icon: "general",
          label: "General",
          sections: [
            {
              id: "general.behavior",
              title: "Behavior",
              items: [
                {
                  id: "app.launch-at-login",
                  title: "Launch Comma at login",
                  description: "Automatically start Comma when you sign in.",
                  keywords: ["startup", "boot"],
                  control: { type: "toggle", checked, onChange },
                },
              ],
            },
          ],
        },
      ],
    },
  ],
});
```

- IDs are stable product identifiers. Never localize or reuse them.
- Provider rows may supply a decorative `icon`. Keep `title` as plain text for
  accessibility and search. Use a `menu` control for secondary account actions.
- Use `integration` for a service card with a status badge, labeled account facts,
  and a short scope/setup note. Status comes from product state, not visual inference.
  Detail actions are callbacks owned by the client.
- Use `status` on a plain row for the state of the thing that row is about, for
  example a computer's reachability or an agent's readiness. It shows in the
  trailing edge beside the controls. It is a report, never a control. An action
  on that state is a `control`.
- A `menu` control with an `icon` renders an icon-only trigger named by its
  `label`. Use it for a row's own overflow actions (rename, delete) so the menu
  does not compete with the setting's control. Keep the labeled button for a
  menu that is the row's primary instrument.
- Give actionable account details an `actionLabel` to describe their action in a
  tooltip and accessible name. The value stays visible.
- Visible copy is localized before registry creation.
- Every setting is searchable automatically by group, category, section,
  title, and description. `keywords` adds localized synonyms. It does not
  replace useful visible copy.
- Search results stay in the sidebar and are grouped by their original category
  and section. Results use the same regular text weight as navigation items.
  The active settings panel does not change until the user selects a result.
  Selection opens its category and focuses the exact setting row.
- Prefer the data controls (`toggle`, `dropdown`, `segmented`, `button`, `menu`,
  `shortcut`, `keybinding`, `keycaps`).
  `shortcut` records Side Chat-style modifier+letter bindings.
  `keybinding` records general app bindings (chords or sequences, max three
  keycaps).
  `keycaps` displays a fixed, non-editable shortcut.
  `custom` is an escape hatch for a genuinely new interaction and should
  normally become a shared control before a second use.
- Use section `titleAction` for list actions. The shared header wraps its title
  and actions when the panel is narrow. Use `onPressTitle` to open row details
  and `density: "compact"` for resource rows with 15px vertical padding.
- Category-level `titleAction` renders opposite the panel title (space-between)
  for actions that apply to the whole category, such as “Reset all to defaults”.
- A category of repeating subjects (one card per computer or per account) is
  still `sections`: one section per subject, its identity row first and its
  settings under it. Keep such a category on the standard rows so it stays
  searchable. Do not build a page of its own with its own list, selection and
  scroll regions.
- A `dropdown` over hundreds of options, such as installed fonts, sets
  `virtualized` with `width: "fixed"`. Only the rows in view mount, and the
  list must be flat. Give an item `fontFamily` to show its label in that face.
  Set `loading` while options still arrive, and start that read from
  `onOpenChange`.
- Use a row's `content` for full-width content that belongs to that setting,
  such as a live preview under its switch. Pass `null` while it is hidden, so
  the slot folds open and shut instead of jumping the page.
- Use `SettingsSliderField` for a number a row's `content` sets with a slider.
  Pass the saved value, its range and default, the localized label, reset label
  and spoken value, and `onValueCommit`. It writes once a drag is released or
  arrow keys stop. Give it `onPaint` to preview the value on each frame of a
  drag or glide without a render.
- Use `NotchWidthSetting` as the Notch row's `content`. Pass the saved width,
  its range and default, and `onValueCommit`. Its `SettingsSliderField` drives
  the preview. Pass `onPreview` to offer showing that width once on the real
  Notch.
- A `model-menu` groups models by maker. Give models a `section` to head runs
  of them, such as model families, inside the maker's menu. The trigger shows
  the chosen model's maker mark, or the `icon` of a chosen top-level item.
- Use `ModelPicker` in a custom row to choose what an Agent runs: models grouped
  by family, the thinking effort beside them, and the account (automatic or one
  profile) in a side panel. A new model waits for its effort. An effort or account is saved at once. The client passes
  localized labels, the models and the accounts that serve each model. Turn
  off `chooseAccount` for a model that runs on its own sign-in.
- Every button on Devices and its compute pages takes
  `deviceSettingsButtonClassName` with `size="sm"`: the 28px button with 12px
  text that Drive's Transfer uses. Overflow menus take `deviceSettingsMenuClassName`. Text links
  on these pages use 12px text.
- Use `CreatedSecretPanel` to show a just-minted credential once: its plaintext,
  an optional example command, copy actions and a dismiss action. Pass localized
  labels and stable test ids. Do not rebuild this panel in a client.
- Keep persistence, native capabilities, and server calls outside `@comma/ui`.
  Pass their current values and callbacks into the registry.

## Device card

`DeviceSettings` shows one card per computer. A card has this order: the
header, the agents section (Codex, Claude Code), Access, a divider, and then
the sandbox (`content`). Agents and Access belong to the station. The sandbox
belongs to the VMM.

- On this computer, an agent row has one status line and a `source` dropdown
  at its trailing edge. The dropdown is the same `SettingsControlView` control
  as Access. Give the status line a `link` for the action that fixes it, for
  example "Add workspace account".
- Do not choose a source for the person. When two sources are available and
  none is chosen, send no `value`. The dropdown then shows its placeholder.
- Show a sign-in as `signIn`, before the dropdown. Show the busy state while
  the page waits in the browser.
- Show a failed read or save of the agents' settings as `agentsProblem`: a
  note in the agents section with a retry link, the same as a failed runtime
  check. Do not show it as an alert at the top of the card.

## Rendering

A row renders again only when its item changes. The client can rebuild the
registry on every render. A change in one row does not render the other rows,
the sidebar, or the dialog frame.

- Text, values, flags, and lists compare by value. Elements compare by type,
  key, and props.
- Callbacks in item data can be new functions on every render. A row calls the
  callback of the latest item when the event occurs, so the callback can use
  the current state of the client.
- Callbacks in element props compare by identity, because the component keeps
  the callback that it rendered with. An element with an inline callback
  renders its row each time. This is correct but slower.
- A component in a row that reads state outside its props must subscribe to
  that state (context or a store). The row does not render again to refresh it.

Use `SettingsPage` for product settings. Lower-level `SettingsSidebar` and
`SettingsPanel` exports exist for Storybook and focused composition tests, not
for rebuilding the product page in a client.

Settings is already a modal surface. Put a surface the reader works through
(a form of several fields, a choice between routes) in `detail`, the
second-level page, not in a dialog stacked on the panel. One question the
reader answers and leaves (a single field, a yes/no) keeps the dialog shape.
Mount it through the category's `overlay`, which stays put whichever view is
showing.
