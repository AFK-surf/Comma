# MarkdownStream

Use this component for incrementally arriving Markdown and completed documents.
Import `MarkdownStream` from `@comma/ui` and load `@comma/ui/styles.css`.

## Document lifetime

Keep `streamId` stable while a reply grows and is committed. Change it for a new
document. `final` ends streaming presentation. It does not create a new document.
Trimming the final source or passing equivalent compiled `nodes` does not reset
document identity. Compatible blocks keep their React identity while the active
batch/window policy keeps them rendered. A real change of block type or structure
can replace the affected subtree. Identity is not guaranteed for arbitrary
insertion, reordering, or a new transport incarnation.

Pass either `content` or parsed `nodes`. The client core parses both
(`@comma/core/markdown`) and owns Markdown semantics, including document-wide
links and footnotes. The document renderer
owns the current AST and stable React paths. Markstream's public `NodeRenderer`
owns batching, deferred visibility, and window layout.
A stream has one `.markdown-renderer`, and each root is a sibling `.node-slot` in
it. Space roots with sibling rules inside that renderer.

Both content parsing and trusted-fragment compilation use the same Markdown
syntax configuration. Double-asterisk bold labels may close after East Asian
punctuation immediately before Han, Hiragana, Katakana, or Hangul text, e.g.
`**标签：**正文`. This rule does not rewrite source text, code, URLs,
single-asterisk emphasis, or underscore delimiters. A block of bare brackets is
math only when its content reads as TeX (`[x^2]`). `[^id]` stays a footnote.
Custom component registration, replacement, and removal use the public registry
(patched in `patches/markstream-react@0.0.52.patch`). A registration for one
message never re-renders another message.

Do not repair stale content by changing all root keys. A resolved reference can
change a child without changing the enclosing quote's raw text. Rendering that
fresh child must not collapse an adjacent expanded code block.

## Text and scheduling

Text is clear immediately by default (`animation="none"`). No character blur,
translation, or word-level layout wrapper is applied in that mode.
`showCursor` remains an independent option for a single cursor at the live prose
tail. Chat replies instead use `animation="reveal"` and disable the cursor.

Prose, list items, definitions, and headings use ordinary wrapping throughout
the document lifetime, including completion. Do not apply `pretty` or `balance`
to streaming blocks. They move completed words back and forth as the next words
arrive. Do not switch wrapping algorithms at `final` either.

`animation="reveal"` immediately renders received text, then paints a short arriving
tail from translucent to its normal color. It uses native CSS Custom Highlight
ranges over existing Text nodes. There are no per-character elements, timers,
blur, translation, geometry measurements, or delayed content playback. Ordinary
text in headings, lists, quotes, and links uses the same path. Code, math,
diagrams, and media keep their own renderers. Each root keeps its own reveal
history, so settled words stay clear across appends, structural changes, and an
equivalent `content` and `nodes` switch. Completion clears paint. Text that cannot
be matched within the bounds in `textRevealIdentity.ts` stays clear. This history
is presentation data, not a Markdown source map.

Durations and limits are in `textReveal.ts`. `maxAnimatedCharacters` can lower
the active range limit. Each document has at most one animation-frame callback.
Only enabled spans carry `data-comma-text-reveal`, the attribute the paint rules
select. Settled and final text does not carry it, so a document's rules restyle
only its live tail.

If Custom Highlight or grapheme segmentation is unavailable, or motion is
reduced, reveal leaves clear text without animation.

Explicit `smoothStreaming={true}` activates the content smoothing queue only with
`animation="blur"` outside complete-blur playback. It does not add a queue to
`none` or `reveal`.

Explicit `animation="blur"` retains optional blur playback.
`ensureBlurAnimation` with no animation override also opts into that mode and
preserves complete-text playback, including code fallback ordering. Respect the
component's reduced-motion behavior. Do not opt chat replies into blur only to
show that tokens are arriving.

The inherited batching, viewport, and virtualization options stay supported.
`nodes` uses the upstream document batch/window settings directly. Deferred
offscreen content uses the upstream visibility/prewarm policy. Do not add a second
rendering queue or timer.

## Code and asynchronous rendering

Code text never waits for syntax highlighting. Shiki returns structured tokens.
React keeps the `pre`, completed lines, and tokens as newer source arrives. The
current tail can show as plain text. A completed unchanged line must not
repeatedly fall back to plain text.

Fence languages matching Comma's built-in AST names (such as `text` or `table`)
use the document's code renderer. They do not become prose or tables. Explicit custom
language registrations and the existing diagram renderers still take priority.

Each mounted code block has at most one asynchronous render in flight and one
replaceable latest request. Scope changes and non-prefix source replacements
invalidate old results. Disposal prevents publication. Do not add polling or
retry. Worker failure leaves current plain code readable.

Visible and near-viewport code activates through the shared viewport observer.
Do not add a per-block scroll debounce, local ResizeObserver, or imperative HTML
replacement. The same token pipeline runs when Worker is unavailable.

## Mixed blocks and media

`blockPresentation="bubbles"` opts a chat surface into grouped reply bubbles.
The default `"document"` keeps the ordinary document layout. Consecutive prose
roots share a `.markdown-stream-bubble[data-kind="prose"]`. Each code block,
table, diagram, block math, media, or custom root receives a separate bubble
whose `data-kind` is its AST type. Original roots inside a bubble retain
`.markdown-stream-bubble-block[data-node-type]` wrappers for block spacing.
When the document's last slot is a bubble, that bubble has `data-last-slot`.
Use this marker to style the end of a reply. Do not find it with a `:has()`
over sibling slots. Chromium checks such a selector again for each streamed node.
The containing chat surface owns bubble color, padding, radius, and spacing.
Root thematic breaks (`---`, `***`, or `___`) end the current bubble without
rendering a line or an empty bubble.

Grouping happens after parsing the complete document, so references, footnotes,
trusted inline elements, and parse hooks keep their document-wide meaning.
Appending prose to a group or adding the next group does not remount completed
roots. Keep the presentation choice stable throughout a reply. In this mode the
upstream batch/window budgets count bubbles.

A list or quote containing a special block receives its own bubble with its
structure intact. Nested code stays in its list item or quotation. Tool
execution activity is chat-owned structured data and gets a separate chat
bubble. Markdown does not infer tool calls from prose, code fences, or JSON text.

- Tables use stable equal-width columns with a minimum column width. Wide tables
  scroll horizontally.
- Code, tables, block math, and diagram source/preview use `ScrollArea` with
  `edgeEffect="none"`. Extend that base component for scrolling behavior.
- Markdown images use a fixed preview frame and contain the whole image. A partial
  source URL reserves the frame but starts no image request. Loading bytes does
  not resize the frame. Standalone previews open the original. Linked images keep
  the containing Markdown link.
- Mermaid has a stable preview area. Incomplete source stays source. Large
  diagrams scroll inside the preview.
- Raw HTML stays under the existing HTML policy. This component does not turn
  arbitrary audio/video markup into a player. The chat layer owns chat
  attachments and trusted task references.

## File document resources

File previews from Drive and chat attachments pass `documentResourcePolicy`
with the host's `onOpenLink` callback, together with `htmlPolicy="escape"`.
This instance-local mode leaves images as text placeholders, keeps Mermaid as
source, and permits only explicit HTTP(S) links through the supplied host action.
Relative links and Comma attachment/task decorators receive no document authority.
Use this mode for file bytes whose embedded URLs must not trigger automatic
network requests.
