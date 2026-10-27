# Design guide for Comma apps

This guide says how a Comma app looks and behaves. It applies to every screen
you build in this repository. Where it disagrees with a shadcn/ui default or
with a habit from another product, this guide wins. The stack and the SDK rules
are in `AGENTS.md`.

A Comma app is built as a mature app is: a phone app first, which the same
code lays out as an iPad app and a web app on wider screens. Its navigation,
type, layout and interaction follow Apple's Human Interface Guidelines, and its
feedback and exceptions follow the WeChat Mini Program design guide.

## 1. Principles

- **Purpose.** One job per app, one focus per screen. Cut what does not serve
  the job.
- **Agency.** Get people to the task at once. No welcome screens, no tours, no
  forced flows. Every action can be undone or cancelled, and every error has a
  way out.
- **Familiarity.** Use the controls in this repository, and use them the same
  way on every screen. A person who learned one screen knows the next.
- **Flexibility.** One app, three layouts: a phone app, an iPad app and a web
  app. Each shows the same functions, laid out for that space and that
  pointer.
- **Simplicity.** Include just what is necessary. Say things in the fewest
  words. Show hierarchy with size, weight and space, not with decoration.
- **Clarity (WeChat).** Navigation is explicit, feedback is immediate, and an
  exception always leaves a path back.
- **Craft.** Spacing, alignment and timing are deliberate. Nothing is a
  default you did not choose.
- **Delight.** Comes from the above done well. Not from decoration.

## 2. Where the app runs

The app renders inside a frame the host owns. The host draws a bar above the
app with the app's name, the version and an actions menu, as a phone's status
bar or a window's title bar. Under it, the app is a whole app: its own
navigation bar, its sections and its screens.

| Surface                          | Width of the frame                    | Height        | Pointer | Layout             |
| -------------------------------- | ------------------------------------- | ------------- | ------- | ------------------ |
| Chat card (a Task's preview)     | 390 px, shown at 60% on a cover       | top 360 px    | mouse   | phone              |
| Right panel (beside a chat)      | 440 px by default, 320 px at least    | the window    | mouse   | phone              |
| Own window (Mac)                 | any; the viewer resizes it            | any           | mouse   | phone, iPad or web |
| Link in a browser (`/a/<token>`) | the browser; 320 to 430 px on a phone | the browser   | touch   | phone, iPad or web |

- **The first 360 px carry the app.** The chat card is the app's launch cover:
  the top 360 px of its first screen, in the phone layout, shown smaller. Most
  people meet the app there first. The first screen starts with its
  content: no hero, no banner, no explanation of what the app is.
- **320 px is the narrowest width.** Every screen works from 320 px wide with
  no horizontal scroll.

## 3. Architecture and size classes

The layout follows the width of the app's own frame, never the device.
`useSizeClass()` in `src/components/navigation.tsx` gives the class; Tailwind's
`sm:` and `lg:` give the same breakpoints in CSS.

| Class   | Width          | Tailwind            | Built as   |
| ------- | -------------- | ------------------- | ---------- |
| Compact | below 640 px   | default (no prefix) | a phone    |
| Regular | 640 to 1023 px | `sm:` and `md:`     | an iPad    |
| Wide    | 1024 px and up | `lg:` and `xl:`     | a web app  |

The components build the three layouts from one description of the app:

|                       | Compact (phone)                    | Regular (iPad)                    | Wide (web)                         |
| --------------------- | ---------------------------------- | --------------------------------- | ---------------------------------- |
| Sections (`AppShell`) | a tab bar at the bottom            | a sidebar                         | a sidebar                          |
| List and detail       | the detail is pushed over the list | side by side (`SplitView`)        | side by side, a wider list         |
| Screen title          | centered in the bar                | at the leading end of the bar     | at the leading end of the bar      |
| A task (`Sheet`)      | a sheet from the bottom            | a centered form sheet             | a centered form sheet              |
| Gutters               | 16 px                              | 24 px                             | 32 px                              |
| Text width            | full                               | `max-w-2xl` (672 px)              | `max-w-2xl` (672 px)               |

- Design the phone layout first, at 360 × 640, then check the iPad and web
  layouts. A screen keeps the same functions in every class; only the
  arrangement changes.
- Keep content and controls in the same places as the width changes.
  `AppShell` keeps every section's screens through a resize.
- Let rows wrap. Put no fixed width on text. A label in another language is
  longer; a number can have more digits.
- Use `@container` queries for a component that appears in columns of
  different widths.
- In a phone browser, the tab bar, a sheet and the toast inset themselves with
  `env(safe-area-inset-bottom)`.
- Test 320 × 360 (a chat card), 390 × 844 with touch (a phone), 834 × 1112
  with touch (an iPad) and 1280 × 800 (the web).

## 4. Structure of the app

```
AppShell                      the app's 2 to 5 sections: tab bar or sidebar
└─ a section                  its own stack of screens
   └─ Screen                  navigation bar, then content that scrolls
      ├─ large title          a section's first screen only
      ├─ ListSection / List   grouped rows, as in Settings
      ├─ EmptyState, ErrorState, LoadingList
      └─ Sheet                a task on top: compose, edit, confirm
```

- **Sections.** 2 to 5 top-level destinations, each with an icon and a
  one-word title. An app with one job has one section, and no tab bar.
- **Screens.** Every screen is a `Screen`. A section's first screen has a large
  title, which moves into the bar once it scrolls away. A pushed screen has its
  title in the bar and a back button labelled with the screen under it.
- **Depth.** At most three screens deep in a section. Choosing the current
  section's tab again goes back to its first screen.
- **Actions.** A screen's actions are in the trailing end of its bar: one or
  two glyph buttons, or one text button. The primary action of a form or a
  sheet is in the sheet's bar, not at the bottom of the content.
- **Reading order is hierarchy.** The most important thing is at the top and
  the leading edge.

## 5. Spacing and alignment

The unit is 4 px. Use these steps and no others:

| Step | Class          | Use                                                          |
| ---- | -------------- | ------------------------------------------------------------ |
| 4    | `gap-1`, `p-1` | inside a control: an icon and its label                      |
| 8    | `gap-2`, `p-2` | between a label and its field; between items of one group    |
| 12   | `gap-3`, `p-3` | inside a row: leading icon, text, trailing control           |
| 16   | `gap-4`, `p-4` | between fields; a card's padding on compact; compact gutters |
| 24   | `gap-6`, `p-6` | between sections; a card's padding on regular and wide       |
| 32   | `gap-8`, `p-8` | between columns on wide; wide gutters                        |

- The space between groups is at least twice the space inside a group. If it is
  not, the groups read as one.
- Group with space first, with a container (`List`, `Card`) second, with a
  separator last.
- Align every text to one leading edge per column. Indent only what is
  subordinate.
- Numbers that line up or change use `tabular-nums`.
- Corner radius: `rounded-md` (8 px) on controls, `rounded-lg` (10 px) on
  inputs and chips, `rounded-xl` (12 px) on lists and cards. A container's
  radius is its child's radius plus the padding between them.

## 6. Typography

The font is Comma's, passed by the host. Do not add a font. Set text by its
role, never by its size: the role's size follows the pointer, as iOS and macOS
differ. On a touch screen (a phone, an iPad) the roles are iOS's default
Dynamic Type sizes; with a mouse they are Comma's desktop sizes.

| Role         | Class               | Touch   | Mouse   | Weight   | Use                                       |
| ------------ | ------------------- | ------- | ------- | -------- | ----------------------------------------- |
| Large title  | `text-large-title`  | 34 / 41 | 24 / 32 | bold     | a section's first screen (`Screen`)       |
| Title 1      | `text-title-1`      | 28 / 34 | 20 / 30 | bold     | one hero value: a total, a score          |
| Title 2      | `text-title-2`      | 22 / 28 | 18 / 28 | semibold | a heading in a detail screen              |
| Title 3      | `text-title-3`      | 20 / 25 | 15 / 24 | semibold | a heading inside long content             |
| Headline     | `text-headline`     | 17 / 22 | 13 / 20 | semibold | a bar title, an empty state's title       |
| Body         | `text-body`         | 17 / 22 | 13 / 20 | regular  | text, rows, controls, fields              |
| Callout      | `text-callout`      | 16 / 21 | 13 / 20 | regular  | a note beside a control                   |
| Subheadline  | `text-subheadline`  | 15 / 20 | 12 / 18 | regular  | a field's label, a sheet's explanation    |
| Footnote     | `text-footnote`     | 13 / 18 | 12 / 18 | regular  | a row's second line, a group's header     |
| Caption 1    | `text-caption-1`    | 12 / 16 | 12 / 18 | regular  | a timestamp, a count                      |
| Caption 2    | `text-caption-2`    | 11 / 13 | 11 / 14 | medium   | tab bar labels only                       |

- The body text is the body role: the base styles set it. Controls use it too.
- Hierarchy comes from role, one step at a time. A row's title is body; its
  detail is footnote in `text-muted-foreground`.
- Lines of body text are at most 70 characters wide (`max-w-prose`).
- A row's title truncates to one line. A description clamps to two lines and
  the full text is in the detail screen. Body text never truncates.
- Labels are words, in sentence case: "Add note", not "ADD" or "Add Note".

## 7. Color

Every color is a role from `src/index.css`. The host sets the roles' values for
light and dark; the app changes no value. Hex, `rgb()`, named colors, gradients
and glows are not allowed.

| Role                | Classes                                                | Use                                                              |
| ------------------- | ------------------------------------------------------ | ---------------------------------------------------------------- |
| Canvas              | `bg-background`                                        | the screen                                                       |
| Card                | `bg-card`, `border`                                    | a list or card on the canvas                                     |
| Grouped surface     | `bg-muted`                                             | a quiet area: an empty state's icon, a code block, a cover       |
| Hover and selection | `bg-accent`                                            | a row under the pointer, a selected tab's background             |
| Text                | `text-foreground`                                      | titles and body                                                  |
| Secondary text      | `text-muted-foreground`                                | descriptions, captions, placeholders, disabled                   |
| Accent              | `bg-primary` `text-primary-foreground`, `text-primary` | the one primary action; links; the selected item's mark          |
| Destructive         | `bg-destructive`, `text-destructive`                   | delete and other actions that lose data; errors                  |
| Success, warning    | `text-success`, `text-warning`                         | a state, beside a word or an icon                                |
| Hairline            | `border-border`                                        | between rows, around cards; `border-border-subtle` inside a card |
| Focus               | `ring-ring`                                            | keyboard focus (the components do this)                          |

- Use color sparingly. One accent per screen. A screen with no color but the
  primary button is normal.
- A color keeps its meaning everywhere: red is only for destruction and errors,
  the accent is only for actions and selection. Never the accent on static
  text, never red on a non-destructive button.
- State is never color alone. A failed row has the word "Failed" or an icon,
  not only a red dot.
- Do not use a role for another purpose: no `border` color as text, no
  `text-muted-foreground` as a background.
- Images and avatars get a hairline: `outline-1 -outline-offset-1 outline-black/10 dark:outline-white/10`.
- Light and dark both work by themselves. Test both. Do not write `dark:`
  color classes; the roles change with the theme.

## 8. Navigation

- Sections are in `AppShell` (`src/components/navigation.tsx`). Inside a
  section, `useNavigation()` gives `push(title, screen)` and `pop()`. Each
  section keeps its own stack, so a person who switches sections and comes back
  finds the screen they left, at the same scroll position.
- A list of items with a detail is a `SplitView`: pushed on a phone, side by
  side on an iPad and the web. The detail screen reads its item by id from
  shared state, so a change shows in both columns.
- The back button is the first thing at the bar's leading end. Escape goes back
  too.
- The URL and `history` do not exist here. Do not use them.
- Do not use a sheet to navigate. A sheet holds one task (compose, edit,
  confirm) and returns to the screen under it.
- A row that opens a detail screen in a stack shows a chevron
  (`ListItem chevron`). In a split view, the open row is selected instead.

## 9. Controls

### Buttons

- One filled `Button` per screen: the primary action. Others: `outline` for
  secondary actions, `ghost` for actions in a row or a header, `link` for
  navigation inside text, `destructive` for actions that lose data.
- Sizes: `default` (36 px) everywhere; `sm` (32 px) inside a row; `icon` for a
  glyph button in a bar, with an `aria-label`. A bar's buttons are `ghost` in
  `text-primary`, as in iOS.
- On touch (`pointer: coarse`) every control is at least 44 px tall. The base
  styles do this. Keep 8 px between adjacent controls.
- A label is a verb: "Save", "Add habit", "Delete". Not "OK", "Yes", "Submit".
- A destructive action needs a confirm step that names what is lost: a `Sheet`
  with a destructive `confirm`. `window.confirm` does not work in the sandbox.
- A button that waits shows it: `disabled` with a spinner or "Saving…" in place
  of its label. Nothing else on the screen changes.

### Lists

The list is the main building block of an app. `List`, `ListItem` and
`ListSection` in `src/components/list.tsx` give inset grouped lists, as in iOS
Settings: rows on one card, a group header and footer in footnote text.

- Rows are 44 px tall on touch and 40 px with a mouse. A row is the whole tap
  target, not only its title.
- A row that navigates or acts is a `button`; it highlights on hover and press.
- A trailing value is `text-muted-foreground tabular-nums`. A trailing control
  is a `Switch`, a small `Button` or a `Badge`.
- A list has at most one trailing element per row.
- An empty list shows `EmptyState`, not nothing.

### Forms

- A `Label` above its field, 8 px apart. Fields 16 px apart. Help text in
  `text-footnote text-muted-foreground` under the field.
- Validate when the person leaves the field, and again on submit. Put the
  message under the field in `text-destructive`, mark the field
  `aria-invalid`, and move focus to the first invalid field. On submit, a
  summary at the top names what to fix when more than one field failed.
- Enter submits a single-field form; the primary action is the submit button.
  Handle the form's `onSubmit` and call `preventDefault()`: a submission never
  leaves the frame, so the handler does the work.
- Reduce input: default values, the last value used, choices instead of free
  text, the viewer's name from `comma.viewer()` when `identity.basic` is
  granted.

### Cards

A `Card` holds one object with several facts or actions. It is not a page
section: do not wrap a list or a form in a card for decoration, and never nest
a card in a card. On compact, prefer a `List` over a grid of cards.

### Sheets

`Sheet` in `src/components/sheet.tsx` holds one task over the current screen:
compose, edit, or confirm.

- Its bar has Cancel at the leading end, the title in the middle, and the
  task's one action at the trailing end ("Add", "Save", "Delete").
- A confirmation has one sentence that names what is lost.
- One sheet at a time. Escape and a press outside it cancel.

### Feedback (WeChat's ladder)

Choose the lightest form that fits:

1. **In place.** The row updates, the switch flips, the count changes. The
   default for any local action.
2. **Toast.** `useToast()` from `src/components/toast.tsx`: one line, 1.8 s,
   for a success or a note that needs no reply ("Saved", "Link copied").
   Never for an error that needs action.
3. **Inline error.** `ErrorState` where the content would be, with the reason
   and a retry.
4. **Sheet.** For a result the person must acknowledge before going on.
5. **Result screen.** For the end of a flow: what happened and what to do
   next.

Loading follows the same idea:

- **Local.** A skeleton (`LoadingList`) in the area that loads, or a spinner in
  the button that started the work. The rest of the screen stays usable.
- **Never** a full-screen spinner for a local action, never two spinners at
  once, never a loading state shorter than 300 ms (keep the old content until
  the new one arrives).
- Work longer than a few seconds shows progress or a cancel.

### States every screen has

| State             | Component         | Content                                            |
| ----------------- | ----------------- | -------------------------------------------------- |
| Loading           | `LoadingList`     | the shape of what will arrive                      |
| Empty             | `EmptyState`      | what this is and what to do first, with the action |
| Error             | `ErrorState`      | what failed, in words, and a retry                 |
| Offline or paused | the host shows it | nothing to do                                      |

## 10. Icons

- `lucide-react` only, at `size-4` (16 px) in buttons and text, `size-5`
  (20 px) in a bar and as a row's leading icon, `size-6` (24 px) in the tab
  bar and an empty state's mark.
- Stroke 2 beside `font-medium` and `font-semibold` text; stroke 1.5
  (`strokeWidth={1.5}`) beside regular text.
- Icons take `currentColor`. State changes the color, never the asset.
- An icon without a label needs `aria-label` on its control, and only when
  the glyph is universal (close, back, more, search).

## 11. Motion

- Respond at once. A press shows on press. Do not wait for the network to show
  that a tap landed.
- Navigation moves along its path, as on iOS: on a phone a pushed screen slides
  in from the trailing edge and a popped one slides back out; a sheet rises
  from the bottom. On an iPad and the web, screens swap at once and a sheet
  scales in from 96%. The components do this; do not add other page motion.
- Animate only `transform` and `opacity`. Never scale from 0.
- Do not animate what people do many times a minute, and never animate on a
  keyboard action.
- Under reduced motion, nothing moves; the components and the base styles
  check it. Use `motion-safe:` on every animation class you add.

## 12. Accessibility

- Every control has a name: visible text, or `aria-label` on a glyph button.
- Every field has a `Label` with `htmlFor`.
- Keyboard: Tab reaches every control in reading order, Enter activates,
  Escape closes or goes back. The focus ring (`ring-ring`) stays visible.
- Contrast: the roles meet 4.5:1 for text. Do not lower opacity on text to
  make it secondary; use `text-muted-foreground`.
- Targets: 32 to 36 px with a pointer, 44 px on touch.
- Text grows: the layout works at 200% browser zoom, and a longer language
  does not clip. Rows wrap; nothing has a fixed height.
- `role="status"` for a toast and a loading area, `role="alert"` for an error.

## 13. Before `app_deploy`

- The app is an `AppShell` of sections, and every screen is a `Screen`.
- The first screen starts with content, under its large title.
- 390 × 844 with touch: a phone app, with a tab bar and 17 px body text.
- 834 × 1112 with touch and 1280 × 800: an iPad and a web app, with a sidebar
  and lists beside their detail.
- 320 px wide: no horizontal scroll, nothing clipped.
- Light and dark both read.
- One filled button per screen.
- Every list has an empty state; every load has a local loading state; every
  failure has a message and a retry.
- Every glyph button has an `aria-label`; every field has a `Label`.
- Numbers that line up are `tabular-nums`.
- Text by role only: no `text-sm`, no `text-[15px]`.
- No hex, no `rgb()`, no arbitrary values (`p-[13px]`), no `dark:` color
  classes, no fonts.
