/** AI Input shell — Figma 7594:546 / 7594:545 */
export const aiInputShell =
  "flex w-full min-w-0 max-w-[744px] flex-col rounded-3xl border border-primary bg-ai-input-panel-bg-input shadow-xs";

/**
 * Drop overlay — Figma 1180:11232. Inset uses spacing-md (8px) so the dashed
 * frame sits inside the existing chrome instead of restyling the outer border.
 * Keep mounted while drops are enabled so enter/exit can use interruptible
 * opacity + scale transitions (never scale(0)).
 */
export const AI_INPUT_DROP_OVERLAY_MIN_HEIGHT_PX = 138;

export const aiInputDropOverlay =
  "ai-input-drop-overlay pointer-events-none absolute inset-md z-10 flex flex-col items-center justify-center gap-lg overflow-hidden border border-dashed border-brand px-xl py-xl not-italic " +
  "opacity-0 scale-[0.97] " +
  "transition-[opacity,transform] duration-[var(--motion-duration-feedback-out)] ease-[var(--motion-easing-smooth-out)] " +
  "data-[drop-active=true]:opacity-100 data-[drop-active=true]:scale-100";

export const aiInputDropOverlayIcons = "relative z-0 flex items-center justify-center";

export const aiInputDropOverlayIcon =
  "relative flex shrink-0 items-center justify-center rounded-full border-2 border-ai-input-panel-bg-input bg-quaternary p-md text-ai-input-panel-icon-primary " +
  "[&:not(:first-child)]:-ml-[5px]";

export const aiInputDropOverlayWash =
  "ai-input-drop-overlay-wash pointer-events-none absolute inset-0 z-[1]";

export const aiInputDropOverlayCopy =
  "relative z-[2] flex w-full flex-col items-center gap-xxs text-center";

export const aiInputDropOverlayTitle =
  "m-0 w-full text-balance text-sm font-medium leading-5 tracking-[-0.14px] text-primary";

export const aiInputDropOverlaySubtitle =
  "m-0 w-full text-pretty text-sm font-regular leading-5 tracking-[-0.14px] text-tertiary";

export const aiInputContent = "flex w-full flex-col gap-md";

/** Composer copy sets at text-sm (13px) — an input the reader is writing in,
    not prose they are reading — on the fixed 20px line grid the height math
    below is built on, which text-sm's own line height already matches. */
export const aiInputPlaceholder =
  "min-h-5 w-full text-sm leading-5 tracking-[-0.14px] text-ai-input-panel-text-placeholder";

/** Default composer starts at two 20px text lines, then grows with content. */
export const AI_INPUT_TEXTAREA_MIN_HEIGHT_PX = 40;
export const AI_INPUT_TEXTAREA_MAX_HEIGHT_PX = 320;

/** Compact composer: a single-line 36px control before promoting to default layout. */
export const AI_INPUT_SMALL_TEXTAREA_MIN_HEIGHT_PX = 36;
/** Expanded small composer starts at two 20px text lines. */
export const AI_INPUT_SMALL_EXPANDED_TEXTAREA_MIN_HEIGHT_PX = 40;
export const AI_INPUT_SMALL_TEXTAREA_MAX_HEIGHT_PX = 120;
export const AI_INPUT_SMALL_TOOLBAR_HEIGHT_PX = 36;

export const aiInputTextarea =
  "w-full resize-none overflow-y-auto bg-transparent text-sm leading-5 tracking-[-0.14px] text-ai-input-panel-text-primary outline-none placeholder:text-ai-input-panel-text-placeholder disabled:cursor-not-allowed";

export const aiInputRichEditor =
  "ai-input-rich-editor w-full overflow-y-auto whitespace-pre-wrap break-words bg-transparent text-sm leading-5 tracking-[-0.14px] text-ai-input-panel-text-primary outline-none empty:before:pointer-events-none empty:before:text-ai-input-panel-text-placeholder empty:before:content-[attr(data-placeholder)]";

/**
 * items-baseline keeps the pill's baseline on the LABEL so prose around the
 * token stays aligned; the glyph opts out via self-center (the InlineTask
 * chip's baseline recipe).
 */
export const aiInputRichToken =
  "relative inline-flex max-w-[min(220px,100%)] appearance-none cursor-pointer select-none items-baseline gap-xxs rounded-full border-0 bg-transparent px-xs align-baseline font-medium text-markdown-text-link outline-none data-[active=true]:bg-brand-primary focus-visible:bg-brand-primary";

/** Pill glyph rides the text color; ai-input-menu.css tints any fills. */
export const aiInputRichTokenIcon =
  "comma-ai-input-token-icon flex size-4 shrink-0 select-none items-center justify-center self-center [&_img]:size-4 [&_svg]:size-4";

export const aiInputRichTokenLabel = "min-w-0 truncate";

export const aiInputRichTokenTooltipPositioner =
  "pointer-events-none fixed z-50 w-[300px] max-w-[calc(100vw-var(--spacing-xl))]";

export const aiInputRichTokenTooltip =
  "ai-input-rich-token-tooltip flex w-full flex-col gap-xxs rounded-md border-[0.5px] border-primary bg-popup-primary px-lg py-md text-left shadow-sm";

export const aiInputRichTokenTooltipTitle =
  "block text-sm font-medium leading-5 text-primary";

export const aiInputRichTokenTooltipText =
  "ai-input-rich-token-tooltip-text block max-h-[90px] overflow-hidden whitespace-normal break-words text-xs font-normal leading-[18px] text-secondary";

/**
 * Trigger menu panel — Figma 1292:12415 (Comma App / AI input). A 353px popover
 * anchored to the trigger's caret position (clamped inside the composer);
 * sections stack with sticky titles and the whole list scrolls in one
 * viewport. left/bottom/width arrive as inline style from the editor.
 */
export const AI_INPUT_MENU_MAX_HEIGHT_PX = 320;
export const AI_INPUT_MENU_WIDTH_PX = 353;

export const aiInputMenuPanel =
  "comma-ai-input-menu absolute z-50 flex max-w-full flex-col rounded-2xl border border-primary bg-ai-input-panel-bg-input shadow-xs";

export const aiInputMenuScrollContent = "flex w-full flex-col gap-sm";

export const aiInputMenuSection = "flex w-full flex-col gap-xxs";

/** Sticky until its own section scrolls away; opaque so rows pass under it. */
export const aiInputMenuSectionLabel =
  "sticky top-0 z-[1] w-full bg-ai-input-panel-bg-input px-xs pt-xs pb-xxs text-xs font-medium text-quaternary";

/**
 * scroll-mt clears the 24px sticky label when keyboard nav reveals a row.
 * Selection bg matches the shell icon buttons' hover (sidebar toggle et al.).
 * Options opt out of button press feedback: their highlight must identify the
 * current navigation target immediately, without fading between old and new rows.
 */
export const aiInputMenuItem =
  "flex w-full min-w-0 cursor-pointer items-center gap-xs scroll-mt-6 rounded-md border-0 bg-transparent p-xs text-left outline-none aria-selected:bg-sidebar-bg-item focus-visible:shadow-focus-gray";

/**
 * Neutral glyphs inherit the Figma markdown-icon token (#7f8286 adaptive);
 * status icons and brand marks carry their own colors over it. The
 * `comma-ai-input-menu-item-icon` hook puts provider marks on a white tile
 * (ai-input-menu.css) so logos keep their original colors on both themes.
 */
export const aiInputMenuItemIcon =
  "comma-ai-input-menu-item-icon flex size-5 shrink-0 items-center justify-center text-markdown-icon-primary [&_img]:size-5 [&_svg]:size-5";

export const aiInputMenuItemLabel = "min-w-0 flex-1 truncate text-sm text-primary";

export const aiInputMenuItemInlineLabel = "min-w-0 truncate text-sm text-primary";

export const aiInputMenuItemInlineDescription =
  "min-w-0 flex-1 truncate text-xs text-quaternary";

export const aiInputMenuItemDescription =
  "min-w-0 max-w-[45%] shrink-0 truncate text-xs text-quaternary";

/** Searching / No results rows keep the item grid so states never reflow. */
export const aiInputMenuStateRow =
  "flex w-full min-w-0 items-center gap-xs p-xs text-sm text-quaternary";

/**
 * One level of the panel: the list, or a group's browse panel in its place.
 * Keyed by level so stepping in or back remounts it and the enter transition
 * in ai-input-menu.css fades the new level in place. The list
 * carries the popover's inset; the browse level starts flush, so its filter
 * field spans the surface the way every other searchable menu's does.
 */
const aiInputMenuLevel = "comma-ai-input-menu-level flex w-full min-w-0 flex-col";
export const aiInputMenuLevelList = `${aiInputMenuLevel} p-md`;
export const aiInputMenuLevelBrowse = aiInputMenuLevel;

/**
 * The "View more" row's trailing chevron: the one glyph that says a row
 * steps into another level rather than inserting something.
 */
export const aiInputMenuItemChevron =
  "comma-ai-input-menu-item-chevron flex size-4 shrink-0 items-center justify-center text-quaternary [&_svg]:size-4";

/**
 * Browse panel — the whole source behind a group, in the list's own box:
 * the menu filter field on top and the sections below, sized to the list's
 * max height so stepping in never resizes the popover.
 */
export const aiInputMenuBrowse = "flex w-full min-w-0 flex-col";

/**
 * The back chevron in the filter field's leading slot. `comma-icon-press` gives
 * it the nav icons' directional press: the glyph slides the way it points.
 */
export const aiInputMenuBrowseBack =
  "comma-icon-press flex size-5 cursor-pointer items-center justify-center rounded-sm border-0 bg-transparent p-0 text-quaternary outline-none hover:text-secondary focus-visible:shadow-focus-gray [&_svg]:size-4";

/** The section list, or one centered state in its place; fills the level's height. */
export const aiInputMenuBrowseBody = "flex min-h-0 w-full min-w-0 flex-1 flex-col p-md";

/** Searching / No files / No results found, centered on both axes. */
export const aiInputMenuBrowseState =
  "comma-ai-input-menu-browse-state flex min-h-0 w-full flex-1 items-center justify-center text-sm text-quaternary";

/** Half the 38px outer height. A finite radius interpolates with the resize. */
export const aiInputSmallCompactShell = "rounded-[19px] px-xs pt-0 pb-0";

/** Expanded small keeps the tighter shell spacing from the compact composer. */
export const aiInputSmallExpandedShell = "px-xs pt-sm pb-0";

export const aiInputSmallShellMotion = "ai-input-small-shell-motion";

/** Prompt and toolbar share one resize surface so attachments stay fixed above them. */
export const aiInputComposer = "flex w-full flex-col gap-xs";

/** Small always uses one relative surface so its bottom toolbar never changes coordinate space. */
export const aiInputSmallLayout = "relative flex w-full flex-col";

/** Compact text starts 42px into the shell: 4px shell + 28px rail + 10px editor inset. */
export const aiInputSmallCompactContent =
  "h-[36px] justify-center pr-[calc(60px+var(--spacing-md)+var(--spacing-xs))]";

export const aiInputSmallCompactContentDefaultLeading = "pl-7";

/** Compact prompt also clears the fixed-width access control when it is visible. */
export const aiInputSmallCompactContentWithAccess =
  "pl-[calc(30px+var(--spacing-xxs)+143px+8px)]";

/** Keep the scaled text line centered within the fixed compact control height. */
export const aiInputSmallTextarea =
  "min-h-[36px] min-w-0 px-2.5 py-[calc((36px-1lh)/2)]";

export const aiInputSmallPromptMotion = "ai-input-small-prompt-motion";

export const aiInputToolbar = "flex h-9 w-full items-center gap-xl";

/** Small keeps the shared 36px row pinned to the composer's bottom edge. */
export const aiInputSmallToolbar =
  "ai-input-small-toolbar-hit-area absolute inset-x-0 bottom-0 h-[36px]";

export const aiInputIconButton =
  "inline-flex shrink-0 items-center justify-center rounded-full text-ai-input-panel-icon-primary outline-none transition-colors focus-visible:shadow-focus-gray disabled:cursor-not-allowed disabled:text-ai-input-panel-icon-disabled";

/** AI Input circular controls share the 30px footprint and tokenized inset. */
export const aiInputControlSmallSize = "size-[30px] p-sm";

export const aiInputAccessButton =
  "inline-flex h-[30px] w-[143px] shrink-0 items-center justify-center gap-xs rounded-full bg-transparent px-md py-xs text-sm leading-5 tracking-[-0.14px] text-ai-input-panel-text-warning outline-none transition-colors hover:bg-quaternary focus-visible:shadow-focus-gray disabled:cursor-not-allowed disabled:text-ai-input-panel-icon-disabled";

export const aiInputSendButton =
  "inline-flex shrink-0 items-center justify-center rounded-full outline-none transition-colors focus-visible:shadow-focus-brand-shadow-xs disabled:cursor-not-allowed";

export const aiInputAttachment =
  "comma-ai-input-attachment group/attachment relative shrink-0";

/**
 * The reveal transition lives in ai-input-attachment.css, not here: the global
 * unlayered button rule declares the whole `transition` shorthand, and an
 * unlayered rule outranks any layered utility regardless of specificity. Press
 * feedback uses the action-specific 0.94 scale in that stylesheet.
 */
export const aiInputAttachmentClose =
  "comma-ai-input-attachment-close absolute -right-1 -top-1 inline-flex size-4 items-center justify-center rounded-full border-[0.5px] border-button-secondary-border bg-ai-input-panel-bg-tag p-xxs text-ai-input-panel-icon-fg outline-none " +
  "opacity-0 " +
  "group-hover/attachment:opacity-100 " +
  "group-focus-within/attachment:opacity-100 " +
  "focus-visible:opacity-100 focus-visible:shadow-focus-gray";

/** Recording row sits beside the existing plus — do not remount that control. */
export const aiInputVoiceRecording =
  "ai-input-voice-recording flex min-w-0 flex-1 items-center gap-[8px]";

export const aiInputVoiceRecordingActions = "flex shrink-0 items-center gap-xs";

export const aiInputVoiceRecordingControl =
  "inline-flex size-[30px] shrink-0 items-center justify-center rounded-full bg-transparent text-ai-input-panel-icon-primary outline-none transition-colors hover:bg-quaternary focus-visible:shadow-focus-gray";

/**
 * Quote reference chip — Figma 8024:3735. Same 48px footprint as an image
 * attachment so a mixed row keeps one baseline, and the same fill and glyph
 * tone as the file attachment's icon surface, since both stand in for content
 * rather than showing it.
 */
export const aiInputQuoteAttachment =
  "flex size-12 items-center justify-center overflow-clip rounded-md bg-panel-bg-file text-ai-input-header-text-secondary outline-none focus-visible:shadow-focus-gray";

/** Quote hover detail — the routine-item hover card's tighter padding. */
export const aiInputQuoteHoverCard = "px-md py-sm";

export const aiInputQuotePreview =
  "flex min-w-0 flex-col gap-xxs text-sm leading-[var(--text-sm--line-height)] text-primary";

export const aiInputQuotePreviewTitle = "font-medium";

/** Long selections stay scannable: pre-wrap keeps the original line breaks. */
export const aiInputQuotePreviewText =
  "m-0 max-h-[240px] overflow-hidden whitespace-pre-wrap text-secondary [overflow-wrap:anywhere]";

/**
 * Image attachment states — Figma 8031:2385 (loading) and 8031:2391 (error).
 * Both share the 48px footprint of a ready thumbnail so the row never reflows
 * as an upload settles.
 */
export const aiInputImageAttachmentTile =
  "flex size-12 items-center justify-center overflow-clip rounded-md";

/** A settled thumbnail keeps the attachment fill and hairline it always had. */
export const aiInputImageAttachmentReady = `${aiInputImageAttachmentTile} border-[0.5px] border-primary bg-ai-input-panel-bg-attachment`;

/**
 * A settled thumbnail is its own preview trigger, so it carries the focus ring
 * the quote chip's button carries.
 */
export const aiInputImageAttachmentPreviewTrigger = `${aiInputImageAttachmentReady} outline-none focus-visible:shadow-focus-gray`;

export const aiInputImageAttachmentLoading = `${aiInputImageAttachmentTile} bg-panel-bg-file text-ai-input-header-text-secondary`;

/**
 * The whole failed tile is the retry target: the reader's instinct is to press
 * the thing that failed, not to hunt for a control beside it.
 *
 * Centering the glyph-over-label stack on the raw box leaves it sitting high —
 * the label's ascent reads as more room above than its descender leaves below.
 * The 4px of top padding pushes the centered stack down the 2px that costs.
 */
export const aiInputImageAttachmentError = `${aiInputImageAttachmentTile} cursor-default flex-col pt-xs bg-error-primary text-error-primary outline-none focus-visible:shadow-focus-gray`;

export const aiInputImageAttachmentErrorLabel = "text-xs font-normal leading-[18px]";
