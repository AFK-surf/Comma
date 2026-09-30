# MarkdownStream

> TLA+ coverage update (2026-09-08): feature-level models referenced below
> have been retired from TLC/CI under the [system-core policy](../../../../../../tla/README.md).
> Their model links, commands and passing-run claims are historical, not current
> verification. Product contracts and implementation regression tests are unchanged.

Use this component for incrementally arriving Markdown and completed documents.
Import `MarkdownStream` from `@comma/ui` and load `@comma/ui/styles.css`.

## Document lifetime

Keep `streamId` stable while a reply grows and is committed. Change it for a new
document. `final` ends streaming presentation; it does not create a new document.
Trimming the final source or handing equivalent compiled `nodes` to the component
does not reset document identity. Compatible blocks retain their React identity
while the active batch/window policy keeps them rendered. Switching from content
to compiled nodes also selects the nodes scheduling policy described below; it
does not promise that every offscreen root stays mounted. A real change of block
type or structure can replace the affected subtree. This is not a guarantee for
arbitrary insertion, reordering, or a new transport incarnation. For content input,
keep `parseOptions` and `customMarkdownIt` references stable while streaming;
replacing them can start a new parser lifetime.

Pass either `content` or parsed `nodes`. Parsing owns Markdown semantics, including
document-wide links, footnotes, custom tags, and parse hooks. The document renderer
owns the current AST and stable React paths. Markstream's public `NodeRenderer`
still owns batching, deferred visibility, and window layout; its shallow raw-text
cache does not decide whether a nested AST update reaches a Comma component.

Both content parsing and trusted-fragment compilation use the same Markdown
syntax configuration. Double-asterisk bold labels may close after East Asian
punctuation immediately before Han, Hiragana, Katakana, or Hangul text, e.g.
`**标签：**正文`. This compatibility rule does not rewrite source text, code,
URLs, single-asterisk emphasis, or underscore delimiters. Standalone `[^id]` markers keep footnote precedence over
tolerant bare-bracket math while a definition's colon is still arriving. Genuine
`[x^2]` and explicit TeX delimiters retain their existing math behavior. Custom
component registration, replacement, and removal use the layout host's existing
public registry update path.

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
to streaming blocks: optimizing a short last line can move already completed
words back and forth as the next words arrive. Do not switch wrapping algorithms
at `final` either. A growing unfinished word can still wrap naturally, and changes
to width, font, or Markdown structure can legitimately change line breaks.

`animation="reveal"` immediately renders received text, then paints a short arriving
tail from translucent to its normal color. Native CSS Custom Highlight ranges
preserve each existing whole Text node; there are no per-character elements,
blur, translation, or delayed content playback. Ordinary text in headings, lists,
quotes, and links uses the same path; code, math, diagrams, and media keep their
own renderers. The document keeps the last committed visible text of each root;
new AST paths are not automatically new words. Ordinary appends inherit the
existing prefix. Structural changes match visible characters in order within
that same root, retaining the age of active ranges and keeping settled words
clear. Separate roots keep separate histories, so a repeated new paragraph still
reveals. Paint uses the renderer’s existing root index within the same document
lifetime; parser source offsets are not a second presentation identity. An
equivalent `content` ↔ compiled `nodes` switch also keeps settled text clear and
preserves active paint ages before completion. Completion clears paint, and a window remount
retains its root’s text history without retaining detached DOM nodes.
If a root wrapper is replaced within one React commit, the replacement can
reclaim active ranges with their original ages. Truly unmounted ranges are
collected by the existing next animation frame; this adds no timer or callback.
Histories of roots removed from the document are discarded.

Structural matching is bounded to 32,768 comparison cells (64 KiB) and a changed
middle of at most 4,096 UTF-16 units per side. Ordinary prefix appends do not
allocate that matrix. For a longer rewrite, a linear common-suffix scan can
preserve an unchanged tail: at most two anchors of at most 64 UTF-16 units must
identify a unique occurrence in each root. Repeated ambiguous suffixes are not
claimed. This keeps active tail ages through an early link rewrite without a
larger diff matrix. If the remaining changed middle still exceeds the budget,
only proven prefix/suffix identity is retained; uncertain text stays clear
instead of becoming translucent. The next proven append still reveals.
Only changed mounted roots are reconciled, and only their latest 220 graphemes
are inspected for paint. This history is presentation data, not a Markdown source
map or a promise to preserve identity across arbitrary root reordering.

Reveal uses 16 color-alpha levels over 150 ms, with 10 ms spacing capped at 90 ms
for a newly arriving tail. Each document has at most one animation-frame callback
and 220 active grapheme ranges; `maxAnimatedCharacters` can lower that limit.
There are no per-character timers or geometry measurements. Each enabled text
update reads its existing span's computed color and supplies that color to the
paint rules. An `isDark` change refreshes it; arbitrary CSS-only color changes are
picked up on the next text/presentation update rather than observed separately.
Active highlights can change a few antialiased edge pixels even at full alpha;
finished ranges are removed to restore the browser's normal text paint.

If Custom Highlight or grapheme segmentation is unavailable, or motion is
reduced, reveal leaves clear text without animation. This is a progressive paint
enhancement, not another content or availability state.

`smoothStreaming` retains its public setting: explicit `true` activates the
existing content smoothing queue only with `animation="blur"` outside
complete-blur playback. It does not add a queue to `none` or `reveal`. Outside
complete-blur playback, completion presents the latest content immediately.

Explicit `animation="blur"` retains optional blur playback.
`ensureBlurAnimation` with no animation override also opts into that mode and
preserves complete-text playback, including code fallback ordering. Respect the
component's reduced-motion behavior; do not opt chat replies into blur simply
to demonstrate that tokens are arriving.

The inherited batching, viewport, and virtualization options remain supported.
Their existing input-mode behavior is retained:

- `nodes` uses the upstream document batch/window settings directly.
- `content` previously used one scheduler per root: a positive initial batch
  budget displayed each root immediately. With batching enabled and
  `maxLiveNodes <= 0`, an initial zero deferred roots to the first batch; with a
  positive live-node limit, zero instead follows the deferred visibility policy.
  The shared layout host preserves these visible outcomes and does not newly
  window a long content document at the default node limit.
- Deferred offscreen content still uses the upstream visibility/prewarm policy.
  Idle prewarming now shares one document queue; independent per-root callback
  timing is not an API guarantee. No second rendering queue or timer compensates
  for that internal scheduling change.

## Code and asynchronous rendering

Code text never waits for syntax highlighting. Shiki returns structured tokens;
React retains the `pre`, completed lines, and tokens as newer source arrives.
The last successful prefix can color that prefix while the current tail is
visible as plain text. New syntax can legitimately change token colors; a
completed unchanged line must not repeatedly fall back to plain text.

Fence languages matching Comma's built-in AST names (such as `text` or `table`)
use the document's code renderer. They do not become prose or tables merely
because the upstream dispatcher tries language names first. Explicit custom
language registrations and the existing diagram renderers still take priority.

Each mounted code block has at most one asynchronous render in flight and one
replaceable latest request. Scope changes and non-prefix source replacements
invalidate old results; disposal prevents publication. No polling or retry is
added. Worker failure leaves current plain code readable. No progress is promised
if the worker never settles. See `tla/salix/MarkdownAsyncRender.tla` for the checked
callback model and fault assumptions.

Visible and near-viewport code activates through the shared viewport observer.
Do not add a per-block scroll debounce, local ResizeObserver, or imperative HTML
replacement. The same token pipeline runs when Worker is unavailable.

## Mixed blocks and media

`blockPresentation="bubbles"` opts a chat surface into grouped reply bubbles;
the default `"document"` keeps the ordinary document layout. Consecutive prose
roots share a `.markdown-stream-bubble[data-kind="prose"]`. Each code block,
table, diagram, block math, media, or custom root receives a separate bubble
whose `data-kind` is its AST type. Original roots inside a bubble retain
`.markdown-stream-bubble-block[data-node-type]` wrappers for block spacing.
The containing chat surface owns bubble color, padding, radius, and spacing.
Root thematic breaks (`---`, `***`, or `___`) end the current bubble without
rendering a line or an empty bubble. Markdown parsing still distinguishes these
from setext headings and literal code; document presentation keeps its rules.

Grouping happens after parsing the complete document, so references, footnotes,
trusted inline elements, and parse hooks keep their document-wide meaning.
Original root indices still own React paths and reveal histories; appending
prose to a group or adding the next group does not remount completed roots.
Keep the presentation choice stable throughout a reply. In this mode the
existing upstream batch/window budgets count bubbles; there is still only one
layout host and no additional scheduling queue.

A list or quote containing a special block receives its own bubble with its
structure intact. Nested code is not lifted out of its list item or quotation,
so list numbering and quoted context remain accurate. Tool execution activity
is chat-owned structured data and receives a separate chat bubble; Markdown
does not infer tool calls from prose, code fences, or JSON text.

- Tables use stable equal-width columns with a minimum column width; wide tables
  scroll horizontally instead of changing existing columns as long cells arrive.
- Code, tables, block math, and diagram source/preview use `ScrollArea` with
  `edgeEffect="none"`. Extend that base component for scrolling behavior.
- Markdown images use a 16:9 preview frame up to 480 px wide and contain the whole
  image. A partial source URL reserves the frame but starts no image request.
  Loading bytes does not resize the frame. Standalone previews open the original;
  linked images preserve the containing Markdown link. Application link routing
  may open its own browser panel.
- Mermaid has a stable 280 px preview area. Incomplete source remains source;
  rendering switches to the completed diagram when available. Large diagrams
  scroll inside the preview.
- Raw HTML remains under the existing HTML policy. This component does not turn
  arbitrary audio/video markup into a player. Chat attachments and trusted task
  references remain owned by the chat layer; its audio/video MIME attachments
  currently render as file cards.

## File document resources

File previews from Drive and chat attachments pass `documentResourcePolicy`
with the host's `onOpenLink` callback, together with `htmlPolicy="escape"`.
This instance-local mode leaves images as text placeholders, keeps Mermaid as
source, and permits only explicit HTTP(S) links through the supplied host action.
Relative links and Comma attachment/task decorators receive no document authority.
Use this mode for file bytes whose embedded URLs must not trigger automatic
network requests. Ordinary chat Markdown keeps its existing resource behavior
when the policy is absent.

## Regression coverage

Nearby component tests cover parsing, scheduling parity, explicit blur, async
coalescing, token identity, and resource errors. App E2E lives in
`clients/packages/app/e2e/markdown-mixed-streaming.spec.ts` and
`chat-reply-streaming.spec.ts`; it exercises the real App/channel with controlled
HTTP/SSE. The chat multimodal integration test covers compiled task references,
image preview leases, and image/file grouping through the real Markdown renderer.
The separate multimodal browser recording uses that same real component tree with
supplied message/draft inputs and local preview leases. It does not exercise Main
IPC, transport, task navigation, or actual downloads. These controlled tests do
not establish remote model or delivery behavior.
