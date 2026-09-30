/* Task board card + column styling tokens (Comma-App Tasks / board view). */

/** Default kanban column width from Comma-App Tasks board (Figma 439:6719). */
export const TASK_BOARD_COLUMN_WIDTH = 345;

/* The 0.5px design stroke is an inset shadow, not a border: Chromium lays a
   fractional border width out as a full CSS pixel, which would eat into the
   card's 12/8 padding and shift every row inside it (same reason .comma-content
   paints its outline this way). The inset shadow sits in --tw-inset-shadow, so
   the selected/focus rings can swap --tw-shadow without erasing the stroke. */
export const taskCardRoot =
  "box-border flex w-full min-w-0 max-w-full shrink-0 flex-col gap-md overflow-hidden rounded-xl bg-todo-kanban-bg-card-primary px-lg py-md text-left inset-shadow-[0_0_0_var(--border-width-0-5)_var(--color-border-primary)] shadow-xs outline-none transition-[box-shadow,background-color]";

export const taskCardInteractive =
  "cursor-pointer hover:bg-quaternary-hover active:bg-quaternary-hover group-active/task-card:bg-quaternary-hover focus-visible:shadow-focus-gray";

export const taskCardSelected = "shadow-focus-gray";

/* Checked into a multi-selection: a thin brand wash laid over the whole card
   (a ::after above the content, so chips and captions tint with it rather
   than punching white holes), deepening a little on hover and press. The
   card keeps its ordinary stroke. */
export const taskCardChecked =
  "relative after:pointer-events-none after:absolute after:inset-0 after:bg-utility-brand-50/30 after:content-[''] " +
  "hover:after:bg-utility-brand-50/45 active:after:bg-utility-brand-50/45 group-active/task-card:after:bg-utility-brand-50/45";

export const taskCardDisabled = "cursor-not-allowed opacity-60";

/** Content block wrapping the title row and the optional meta row. */
export const taskCardBody = "flex w-full min-w-0 flex-col gap-xs";

export const taskCardRow = "flex w-full min-w-0 items-start gap-md";

/** 18px status-icon slot, nudged down to sit on the first text line. */
export const taskCardIconSlot = "flex shrink-0 pt-xxs";

export const taskCardIcon =
  "comma-icon-slot inline-flex size-[18px] items-center justify-center [&_svg]:size-full";

/** Mirrors the icon slot width so meta content aligns under the title text. */
export const taskCardMetaSpacer = "size-[18px] shrink-0 pt-xxs";

export const taskCardTitle =
  "min-w-0 flex-1 text-sm font-medium leading-5 tracking-[-0.14px] text-primary [word-break:break-word] [overflow-wrap:anywhere]";

export const taskCardMeta =
  "flex min-w-0 flex-1 items-center gap-xs py-xxs text-sm font-normal leading-5 tracking-[-0.14px] text-quaternary";

export const taskCardMetaText = "min-w-0 flex-1 truncate";

export const taskCardBadges = "flex flex-wrap items-center gap-xs";

export const taskCardFooter =
  "w-full text-sm font-normal leading-5 tracking-[-0.14px] text-quaternary [word-break:break-word]";

/* Drag-to-reorder inside one column. The slot keeps the column's own card gap,
   so lifting a card out of it leaves a well the exact size of the card. */
export const taskCardReorderList = "relative flex w-full min-w-0 flex-col gap-lg";

export const taskCardReorderSlot = "relative min-w-0";

/** The well a lifted card came out of: the card's own shape, left empty. */
export const taskCardReorderSlotDragging = "rounded-xl bg-quaternary";

export const taskCardReorderContent = "min-w-0";

/* While a card is held, every other card sits above the well: the well is the
   origin slot's own background, and a neighbour earlier in the DOM would
   otherwise slide underneath it — painted over by the gray it is supposed to
   cover. The held card stays on top of them all. */
export const taskCardReorderContentYielding = "relative z-[1]";

/* A lifted card floats over its neighbours; the radius is the card's own, so
   the shadow it casts traces the card and not this wrapper's box. It stops
   taking pointer events for the length of the drag — the gesture is driven off
   the window — and forces the card's own surface back over the pressed tint
   that the still-held button would otherwise keep painting: a card being
   carried should read as lifted, not as stuck mid-click. */
export const taskCardReorderContentDragging =
  "pointer-events-none relative z-10 rounded-xl shadow-lg [&_[data-slot=task-card]]:bg-todo-kanban-bg-card-primary!";

export const taskBoardRoot = "h-full min-h-0 w-full";

export const taskBoardTrack =
  "box-border flex h-full min-h-0 w-max items-stretch gap-md px-md pb-md";

export const taskBoardColumnRoot =
  "box-border flex h-full max-w-full min-h-0 min-w-0 shrink-0 flex-col overflow-hidden rounded-md bg-todo-kanban-bg-column-primary";

export const taskBoardColumnHeader =
  "box-border flex w-full min-w-0 shrink-0 items-center gap-md px-lg pt-lg pb-2xl";

export const taskBoardColumnHeaderIcon =
  "comma-icon-slot inline-flex size-[18px] shrink-0 items-center justify-center [&_svg]:size-full";

export const taskBoardColumnHeaderLabel =
  "truncate text-sm font-medium leading-5 tracking-[-0.14px] text-primary";

export const taskBoardColumnHeaderCount =
  "shrink-0 font-mono text-sm font-normal leading-5 tracking-[-0.14px] text-quaternary";

/** basis-0 keeps the column body scroll region inside the flex height chain. */
export const taskBoardColumnScroll =
  "box-border max-w-full min-h-0 min-w-0 w-full flex-1 basis-0 overflow-x-hidden";

/* overflow-x is `clip`, not `hidden`: `hidden` would compute overflow-y to
   `auto` and turn the body into a clip box exactly as tall as its cards, cutting
   off a card that is dragged below the last slot. */
export const taskBoardColumnBody =
  "box-border flex w-full min-w-0 max-w-full flex-col gap-lg overflow-x-clip px-lg pb-lg";

export const taskBoardColumnViewport = "min-w-0 overflow-x-hidden overscroll-x-contain";

export const taskBoardColumnEmpty =
  "py-lg text-sm font-normal leading-5 text-quaternary";
