# Settings

## Ownership

`@comma/ui` owns the complete settings surface: navigation, category icons,
search, empty states, setting rows, and controls. Product clients provide a
localized registry plus values and callbacks; they must not rebuild settings
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
- Provider rows may supply a decorative `icon`; keep `title` as plain text for
  accessibility and search. Use a `menu` control for secondary account actions.
- Use `integration` for a service card with a status badge, labeled account facts,
  and a short scope/setup note. Status comes from product state, not visual inference;
  detail actions are callbacks owned by the client.
- Use `status` on a plain row for the state of the thing that row is about — a
  computer's reachability, an agent's readiness. It reports in the trailing edge
  beside the controls, so a card of rows reads as one column of states. It is a
  report, never a control; an action on that state is a `control`.
- A `menu` control with an `icon` renders an icon-only trigger named by its
  `label`. Use it for a row's own overflow actions (rename, delete) so the menu
  does not compete with the setting's control; keep the labelled button for a
  menu that is the row's primary instrument.
- Give actionable account details an `actionLabel` to describe their action in a
  tooltip and accessible name. The value remains visible; long values wrap and
  the facts stack when the card has limited space.
- Visible copy is localized before registry creation.
- Every setting is searchable automatically by group, category, section,
  title, and description. `keywords` adds localized synonyms; it is not a
  replacement for useful visible copy.
- Search results stay in the sidebar and are grouped by their original category
  and section. Results use the same regular text weight as navigation items.
  The active settings panel does not change until the user selects a result;
  selection then opens its category and focuses the exact setting row.
- Prefer the data controls (`toggle`, `dropdown`, `segmented`, `button`, `menu`,
  `shortcut`, `keybinding`, `keycaps`).
  `shortcut` records Side Chat-style modifier+letter bindings.
  `keybinding` records general app bindings (chords or sequences, max three
  keycaps).
  `keycaps` displays a fixed, non-editable shortcut.
  `custom` is an escape hatch for a genuinely new interaction and should
  normally become a shared control before a second use.
- Category-level `titleAction` renders opposite the panel title (space-between)
  for actions that apply to the whole category, such as “Reset all to defaults”.
- A category of repeating subjects — one card per computer, per account — is
  still `sections`: one section per subject, its identity row first and its
  settings under it. Keep such a category on the standard rows so it stays
  searchable and scrolls with every other page, rather than a page of its own
  with its own list, selection and scroll regions.
- A `dropdown` over hundreds of options, such as installed fonts, sets
  `virtualized` with `width: "fixed"`. Only the rows in view mount, and the
  list must be flat. Give an item `fontFamily` to show its label in that face.
  Set `loading` while options still arrive, and start that read from
  `onOpenChange`.
- Use a row's `content` for full-width content that belongs to that setting,
  such as a live preview under its switch. Pass `null` while it is hidden, so
  the slot folds open and shut instead of jumping the page.
- Use `NotchWidthSetting` as the Notch row's `content`. Pass the saved width,
  its range and default, and `onValueCommit`; its slider writes once a drag is
  released or arrow keys stop, and animates the preview itself. Pass
  `onPreview` to offer showing that width once on the real Notch.
- Use `SettingsChoiceTable` in a stacked custom row for a searchable single choice.
  Keep its search and fetch action in the table toolbar. Pass localized labels and controlled values.
- Use `ModelTemplatesTable` in a stacked custom row for custom models.
  Use `ModelTemplateDialog` for model creation and editing. Keep assignment controls outside the dialog.
- Use `CreatedSecretPanel` to show a just-minted credential once: its plaintext,
  an optional example command, copy actions and a dismiss action. Pass localized
  labels and stable test ids; do not rebuild this panel in a client.
- Use `SubscriptionAccounts` in a stacked custom row for subscription account management.
  Keep import and connection actions in its toolbar. Use dialogs for credential entry and deletion.
  The client supplies localized account rows, quota values, and mutation callbacks.
- Keep persistence, native capabilities, and server calls outside `@comma/ui`.
  Pass their current values and callbacks into the registry.

## Rendering

A row renders again only when its item changes. The client can rebuild the
registry on every render; a change in one row does not render the other rows,
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

Settings is already a modal surface, so a surface the reader has to read and
work through — a form of several fields, a choice between routes — belongs in
`detail`, the second-level page, rather than a dialog stacked on the panel.
One question the reader answers and leaves — a single field, a yes/no — keeps
the dialog shape; mount it through the category's `overlay`, which stays put
whichever view is showing.
