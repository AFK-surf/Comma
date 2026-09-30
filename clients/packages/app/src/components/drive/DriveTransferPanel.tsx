import { useCommaMessages } from "@comma/i18n/react";
import {
  CircleCheckFilledIcon,
  CloudSimpleUploadIcon,
  cx,
  DownloadIcon,
  ExclamationTriangleIcon,
  FileIcon,
  Folder1Icon,
  LoadingCircleIcon,
  registerToastObstructionTarget,
  ScrollArea,
  XIcon,
} from "@comma/ui";
import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import { ShellIconButtonControl } from "../ShellIconButton";
import { panelTabButton } from "../panelTabButton";
import { DriveFileName } from "./DriveFileName";
import type { DriveTransfer, DriveTransferDirection } from "./driveStore";

/**
 * The panel shares the bottom-right corner with the toast stack and moves in
 * the same direction, but on a quicker clock: it is a toggled surface, opened
 * many times a session, so it runs shorter than a toast's one-off arrival. A
 * strong ease-out both ways, with an exit that finishes sooner than the entry
 * did. The exit stays ease-out because the close click is the moment the user
 * watches most closely; an ease-in would hold the box still through that beat.
 */
const panelMotion = [
  "translate-y-0 opacity-100 transition-[opacity,translate,visibility]",
  "duration-[var(--motion-duration-panel-enter)] ease-[var(--motion-easing-smooth-out)]",
  // Closed keeps the box mounted through its exit, then `visibility` flips at
  // the end of the transition so the panel really leaves the a11y tree.
  "data-[open=false]:pointer-events-none data-[open=false]:invisible",
  "data-[open=false]:translate-y-2 data-[open=false]:opacity-0",
  "data-[open=false]:duration-[var(--motion-duration-panel-exit)]",
  "motion-reduce:transition-none",
].join(" ");

/**
 * Switching tabs or landing a transfer changes how tall the panel is. Height is
 * the one thing here that cannot be a transform: the box has to actually
 * resize, and it is anchored at the bottom, so it grows upward from its corner
 * instead of pushing the page around.
 */
const panelBodyMotion =
  "transition-[height] duration-[var(--motion-duration-spatial-move)] " +
  "ease-[var(--motion-easing-spatial-move)] motion-reduce:transition-none";

/**
 * Measures one pane's natural height so the panel can size itself to the
 * taller of the two. A callback ref, not an effect: a pane moves between the
 * scroller and the off-screen measuring slot when the tab changes, and the
 * observer has to follow it to the node it actually landed on. `revision` is
 * whatever the pane's rows come from; a new one re-measures before paint.
 */
function useNaturalHeight(revision: unknown) {
  const [height, setHeight] = useState<number>();
  const nodeRef = useRef<HTMLDivElement | null>(null);
  const observerRef = useRef<ResizeObserver | null>(null);

  const ref = useCallback((node: HTMLDivElement | null) => {
    observerRef.current?.disconnect();
    observerRef.current = null;
    nodeRef.current = node;
    if (!node) return;
    setHeight(node.getBoundingClientRect().height);
    const observer = new ResizeObserver(([entry]) => {
      if (entry) setHeight(entry.contentRect.height);
    });
    observer.observe(node);
    observerRef.current = observer;
  }, []);

  // The observer reports after layout, a frame behind a render that changed
  // the pane's rows — the open that also drops dismissed transfers, say. The
  // first painted frame has to carry the new height already, so every commit
  // measures again here, before paint; the observer still covers what no
  // render caused, such as a name wrapping differently.
  useLayoutEffect(() => {
    const node = nodeRef.current;
    if (node) setHeight(node.getBoundingClientRect().height);
  }, [revision]);

  return { height, ref };
}

/**
 * The panel stops growing at 500px. Its tabs row and padding are fixed, so
 * the list below takes whatever is left and scrolls inside it — the tabs and
 * the close button stay put however long the list gets.
 */
const panelMaxHeightPx = 500;
/** p-xl top and bottom (32) + the 28px tabs row + the gap-xl below it. */
const panelChromePx = 76;
const listMaxHeightPx = panelMaxHeightPx - panelChromePx;

const doneCount = (transfers: readonly DriveTransfer[]) =>
  transfers.filter((transfer) => transfer.status === "success").length;

function DriveTransferRow({
  onRetry,
  onReveal,
  retryLabel,
  revealActionLabel,
  transfer,
}: {
  onRetry: (transfer: DriveTransfer) => void;
  onReveal: ((transfer: DriveTransfer) => void) | undefined;
  retryLabel: string;
  revealActionLabel: string | undefined;
  transfer: DriveTransfer;
}) {
  return (
    <div
      className="flex w-full items-center gap-sm rounded-md border border-primary p-sm"
      data-status={transfer.status}
      data-testid={`drive-transfer-${transfer.id}`}
    >
      <span className="relative flex size-9 shrink-0 items-center justify-center overflow-hidden rounded-xs bg-quaternary">
        {transfer.status === "in_progress" ? (
          <LoadingCircleIcon
            aria-hidden
            className="size-7 animate-spin text-quaternary"
          />
        ) : transfer.direction === "download" ? (
          <DownloadIcon aria-hidden className="size-5 text-quaternary" />
        ) : (
          <FileIcon aria-hidden className="size-5 text-quaternary" />
        )}
      </span>
      <span className="flex min-w-0 flex-1 flex-col">
        <DriveFileName className="text-sm text-primary" name={transfer.fileName} />
        {transfer.status === "error" ? (
          <span className="flex min-w-0 items-center gap-xs">
            <span className="min-w-0 truncate text-sm text-error-primary">
              {transfer.errorMessage}
            </span>
            <button
              className="inline-flex shrink-0 items-center justify-center rounded-md border border-button-secondary-border bg-button-secondary-bg px-xs py-xxs text-xs font-medium text-button-secondary-fg shadow-xs transition-colors hover:bg-secondary focus:outline-none focus-visible:shadow-focus-gray-shadow-xs"
              onClick={() => onRetry(transfer)}
              type="button"
            >
              <span className="px-xxs">{retryLabel}</span>
            </button>
          </span>
        ) : (
          <span className="min-w-0 truncate text-sm text-quaternary">
            {transfer.detail}
          </span>
        )}
      </span>
      {transfer.status === "success" ? (
        <span className="flex items-start gap-sm self-stretch">
          <CircleCheckFilledIcon
            aria-hidden
            className="size-4 text-fg-success-primary"
          />
          {onReveal &&
          revealActionLabel !== undefined &&
          transfer.downloadRef !== undefined ? (
            <button
              aria-label={revealActionLabel}
              className="inline-flex size-4 items-center justify-center rounded-sm border-0 bg-transparent p-0 text-quaternary outline-none transition-colors hover:text-secondary focus-visible:shadow-focus-gray"
              data-testid={`drive-transfer-reveal-${transfer.id}`}
              onClick={() => onReveal(transfer)}
              type="button"
            >
              <Folder1Icon aria-hidden className="size-4" />
            </button>
          ) : null}
        </span>
      ) : transfer.status === "error" ? (
        <span className="flex items-start self-stretch">
          <ExclamationTriangleIcon
            aria-hidden
            className="size-4 text-fg-error-primary"
          />
        </span>
      ) : null}
    </div>
  );
}

/** One tab's list, rendered the same whether it is on screen or being measured. */
function DriveTransferPane({
  direction,
  onRetry,
  onReveal,
  ref,
  retryLabel,
  revealActionLabel,
  transfers,
}: {
  direction: DriveTransferDirection;
  onRetry: (transfer: DriveTransfer) => void;
  onReveal: ((transfer: DriveTransfer) => void) | undefined;
  ref: (node: HTMLDivElement | null) => void;
  retryLabel: string;
  revealActionLabel: string | undefined;
  transfers: readonly DriveTransfer[];
}) {
  const messages = useCommaMessages();
  return (
    <div ref={ref}>
      {transfers.length === 0 ? (
        <div className="flex h-[118px] w-full flex-col items-center justify-center gap-md">
          {direction === "upload" ? (
            <CloudSimpleUploadIcon aria-hidden className="size-5 text-quaternary" />
          ) : (
            <DownloadIcon aria-hidden className="size-5 text-quaternary" />
          )}
          <p className="m-0 text-center text-sm text-quaternary">
            {direction === "upload"
              ? messages.drive_transfers_empty_upload()
              : messages.drive_transfers_empty_download()}
          </p>
        </div>
      ) : (
        <div className="flex w-full flex-col gap-md">
          {transfers.map((transfer) => (
            <DriveTransferRow
              key={transfer.id}
              onRetry={onRetry}
              onReveal={onReveal}
              retryLabel={retryLabel}
              revealActionLabel={revealActionLabel}
              transfer={transfer}
            />
          ))}
        </div>
      )}
    </div>
  );
}

export function DriveTransferPanel({
  onClose,
  onRetry,
  onReveal,
  open,
  revealActionLabel,
  transfers,
}: {
  onClose: () => void;
  onRetry: (transfer: DriveTransfer) => void;
  /** Absent where the runtime cannot reveal saved downloads (web). */
  onReveal: ((transfer: DriveTransfer) => void) | undefined;
  open: boolean;
  revealActionLabel: string | undefined;
  transfers: readonly DriveTransfer[];
}) {
  const messages = useCommaMessages();
  const uploads = transfers.filter((transfer) => transfer.direction === "upload");
  const downloads = transfers.filter((transfer) => transfer.direction === "download");
  // Land on whichever side is actually moving when the panel opens. The panel
  // stays mounted through its exit animation, so this re-runs on every open
  // rather than only on mount.
  const movingTab = (): DriveTransferDirection =>
    uploads.length === 0 && downloads.length > 0 ? "download" : "upload";
  const [tab, setTab] = useState<DriveTransferDirection>(movingTab);
  const [lastOpen, setLastOpen] = useState(open);
  if (open !== lastOpen) {
    setLastOpen(open);
    if (open) setTab(movingTab());
  }
  // Both panes are measured, and the panel takes the taller. Switching tabs
  // must not move the tabs row or the close button out from under the pointer,
  // so the shorter side sits in the height the longer one asks for.
  const uploadBody = useNaturalHeight(transfers);
  const downloadBody = useNaturalHeight(transfers);
  const natural = Math.max(uploadBody.height ?? 0, downloadBody.height ?? 0);
  const bodyHeight = natural > 0 ? Math.min(natural, listMaxHeightPx) : undefined;
  // Height animates only once the panel has been on screen for a frame. The
  // commit that opens it may also be the one that drops dismissed rows, and
  // that resize belongs to the closed panel: it must land before the first
  // frame, not play out as the box grows and shrinks in front of the user.
  const [settled, setSettled] = useState(false);
  useEffect(() => {
    if (!open) {
      setSettled(false);
      return undefined;
    }
    const frame = requestAnimationFrame(() => setSettled(true));
    return () => cancelAnimationFrame(frame);
  }, [open]);
  // Reads the live obstruction through `--comma-toast-obstruction-right` set on
  // this element (see `toastObstruction`).
  const panelRef = useRef<HTMLElement | null>(null);
  useLayoutEffect(() => {
    const panel = panelRef.current;
    if (!panel) return undefined;
    return registerToastObstructionTarget(panel);
  }, []);

  return (
    <section
      aria-hidden={!open}
      aria-label={messages.drive_transfers_title()}
      className={cx(
        // Shares the toast stack's corner, so it also steps left of whatever
        // claims the window's right edge (the open right sidebar, a native
        // browser view) via the same `--comma-toast-obstruction-right` channel.
        "fixed right-[calc(var(--spacing-3xl)+var(--comma-toast-obstruction-right,0px))] bottom-3xl z-[9] flex w-toast-single max-w-[calc(100vw-var(--comma-toast-obstruction-right,0px)-var(--spacing-3xl)*2)] flex-col gap-xl rounded-xl border-[length:var(--border-width-0-5)] border-solid border-primary bg-popup-secondary p-xl shadow-md",
        panelMotion
      )}
      data-open={open ? "true" : "false"}
      data-testid="drive-transfer-panel"
      inert={open ? undefined : true}
      ref={panelRef}
      style={{ maxHeight: panelMaxHeightPx }}
    >
      <div className="flex w-full items-center justify-between gap-md">
        <div className="flex min-w-0 flex-1 items-center gap-xs">
          <button
            className={panelTabButton(tab === "upload")}
            data-testid="drive-transfer-tab-upload"
            onClick={() => setTab("upload")}
            type="button"
          >
            {messages.drive_transfers_upload_tab({
              done: String(doneCount(uploads)),
              total: String(uploads.length),
            })}
          </button>
          <button
            className={panelTabButton(tab === "download")}
            data-testid="drive-transfer-tab-download"
            onClick={() => setTab("download")}
            type="button"
          >
            {messages.drive_transfers_download_tab({
              done: String(doneCount(downloads)),
              total: String(downloads.length),
            })}
          </button>
        </div>
        {/* The same control as the shell's sidebar toggle: one dismiss
            affordance across the app, hit target and hover included. */}
        <ShellIconButtonControl
          aria-label={messages.drive_transfers_close()}
          className="shrink-0"
          data-testid="drive-transfer-close"
          icon={<XIcon className="comma-input-icon" />}
          onPress={onClose}
        />
      </div>
      {/* The tab that is not showing is measured here instead: inside the
          scroller it would lend the visible tab its scroll length, and out of
          the panel's flow it costs the layout nothing. `invisible` keeps it
          off the screen and out of the tab order without collapsing its box. */}
      <div
        aria-hidden
        className="pointer-events-none invisible absolute inset-x-xl top-xl"
        data-testid="drive-transfer-measure"
      >
        {tab === "upload" ? (
          <DriveTransferPane
            direction="download"
            onRetry={onRetry}
            onReveal={onReveal}
            ref={downloadBody.ref}
            retryLabel={messages.drive_transfer_retry()}
            revealActionLabel={revealActionLabel}
            transfers={downloads}
          />
        ) : (
          <DriveTransferPane
            direction="upload"
            onRetry={onRetry}
            onReveal={onReveal}
            ref={uploadBody.ref}
            retryLabel={messages.drive_transfer_retry()}
            revealActionLabel={revealActionLabel}
            transfers={uploads}
          />
        )}
      </div>
      <div
        className={cx("overflow-hidden", settled && panelBodyMotion)}
        data-testid="drive-transfer-body"
        style={{ height: bodyHeight }}
      >
        {/* The scroller has to be the thing with the definite height: a
            `max-height` alone leaves the viewport as tall as its content, so
            `.comma-scroll-area`'s own `overflow: hidden` clips the list instead
            of letting it scroll. The animated wrapper carries the pixel
            height, this fills it, and the panes inside stay free to report
            their natural heights.

            It runs out to the panel's edge (`-mr-xl` cancels the panel's own
            right padding) and the rows put that padding back, so the bar rides
            in the gutter instead of sitting on top of a row. The edge mask
            fades the list into the panel's chrome rather than cutting a row in
            half against it. */}
        <ScrollArea
          className="-mr-xl h-full"
          contentClassName="pr-xl"
          edgeMask={{ enabled: true, size: 24 }}
          viewportClassName="h-full"
        >
          {tab === "upload" ? (
            <DriveTransferPane
              direction="upload"
              onRetry={onRetry}
              onReveal={onReveal}
              ref={uploadBody.ref}
              retryLabel={messages.drive_transfer_retry()}
              revealActionLabel={revealActionLabel}
              transfers={uploads}
            />
          ) : (
            <DriveTransferPane
              direction="download"
              onRetry={onRetry}
              onReveal={onReveal}
              ref={downloadBody.ref}
              retryLabel={messages.drive_transfer_retry()}
              revealActionLabel={revealActionLabel}
              transfers={downloads}
            />
          )}
        </ScrollArea>
      </div>
    </section>
  );
}
