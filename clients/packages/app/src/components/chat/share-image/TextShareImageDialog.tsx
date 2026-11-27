import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import { uiClock, type CancelUiTimer } from "@comma/ui/clock";
import { Button } from "@comma/ui/components/Button";
import {
  CheckIcon,
  ChevronLeftSmallIcon,
  ChevronRightSmallIcon,
  CopyIcon,
  DownloadIcon,
  XIcon,
} from "@comma/ui/components/icons";
import { NativeSurfaceSuppressor } from "@comma/ui/components/native-surface/NativeSurfaceSuppressor";
import { toast } from "@comma/ui/components/toast";
import {
  useCallback,
  useEffect,
  useId,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import { Dialog as RacDialog, Modal, ModalOverlay } from "react-aria-components";
import { downloadFile } from "../../../runtime-files/fileDownloads";
import { copyImageBlob } from "../../../runtime-files/imageClipboard";
import type { ChatSelectionSharePayload } from "../conversation/chatMessageContextMenu";
import {
  formatSwissDate,
  renderShareCardToCanvas,
  resolveShareCardFontFamily,
  type ShareCardRenderOptions,
} from "./renderShareCardCanvas";
import { encodeShareQr } from "./shareQrCode";
import {
  COMMA_ANDROID_STORE_URL,
  COMMA_IOS_STORE_URL,
  MAX_SHARE_PAGES,
  planShareCards,
  type ShareCardMode,
} from "./shareTextLayout";

export interface TextShareImageDialogProps {
  isOpen: boolean;
  payload: ChatSelectionSharePayload | null;
  /** The Task title the selection comes from. */
  sourceTitle?: string | undefined;
  onClose: () => void;
  iosStoreUrl?: string | undefined;
  androidStoreUrl?: string | undefined;
}

type CardSwap = {
  direction: "next" | "prev";
  /** Alternates so each swap restarts the CSS animation. */
  phase: 0 | 1;
};

function canvasToPngBlob(canvas: HTMLCanvasElement): Promise<Blob> {
  return new Promise((resolve, reject) => {
    canvas.toBlob((blob) => {
      if (blob) resolve(blob);
      else reject(new Error("PNG encode failed"));
    }, "image/png");
  });
}

function shareFileName(
  dateLabel: string,
  pageIndex?: number,
  pageCount?: number
): string {
  const stamp = dateLabel.replace(/\./g, "");
  if (pageCount && pageCount > 1 && pageIndex !== undefined) {
    const num = String(pageIndex + 1).padStart(2, "0");
    return `comma-share-${stamp}-${num}.png`;
  }
  return `comma-share-${stamp}.png`;
}

/** Copies the card on screen into the outgoing layer so it can leave while the next one arrives. */
function snapshotCard(from: HTMLCanvasElement | null, to: HTMLCanvasElement | null) {
  if (!from || !to || from.width === 0 || from.height === 0) return;
  to.width = from.width;
  to.height = from.height;
  to.getContext("2d")?.drawImage(from, 0, 0);
}

export function TextShareImageDialog({
  isOpen,
  payload,
  sourceTitle = "",
  onClose,
  iosStoreUrl = COMMA_IOS_STORE_URL,
  androidStoreUrl = COMMA_ANDROID_STORE_URL,
}: TextShareImageDialogProps) {
  const locale = useCommaLocale();
  const messages = useCommaMessages();
  const titleId = useId();
  const noticeId = useId();

  // Hold the last payload through the exit animation so the card stays on
  // screen until the dialog has left.
  const [retainedPayload, setRetainedPayload] =
    useState<ChatSelectionSharePayload | null>(payload);
  useEffect(() => {
    if (payload) setRetainedPayload(payload);
  }, [payload]);

  const activePayload = payload ?? retainedPayload;

  const [mode, setMode] = useState<ShareCardMode>("excerpt");
  const [pageIndex, setPageIndex] = useState(0);
  const [swap, setSwap] = useState<CardSwap | null>(null);
  const [copied, setCopied] = useState(false);
  const [saving, setSaving] = useState(false);
  const [dateLabel, setDateLabel] = useState(() => formatSwissDate(uiClock.now()));
  const [clientFontFamily, setClientFontFamily] = useState(() =>
    resolveShareCardFontFamily()
  );

  const previewCanvasRef = useRef<HTMLCanvasElement | null>(null);
  const outgoingCanvasRef = useRef<HTMLCanvasElement | null>(null);
  const stageRef = useRef<HTMLDivElement | null>(null);
  const copiedResetRef = useRef<CancelUiTimer | null>(null);

  // Follow Comma Appearance font-family changes on documentElement while open.
  useEffect(() => {
    if (!isOpen || typeof document === "undefined") return undefined;
    const syncFont = () => {
      const next = resolveShareCardFontFamily();
      setClientFontFamily((current) => (current === next ? current : next));
    };
    syncFont();
    if (typeof MutationObserver === "undefined") return undefined;
    const observer = new MutationObserver(syncFont);
    observer.observe(document.documentElement, {
      attributes: true,
      attributeFilter: ["style", "data-comma-font-family"],
    });
    return () => observer.disconnect();
  }, [isOpen]);

  // A fresh selection starts on its first card.
  useEffect(() => {
    if (isOpen && payload) {
      setMode("excerpt");
      setPageIndex(0);
      setSwap(null);
      setCopied(false);
      setDateLabel(formatSwissDate(uiClock.now()));
    }
  }, [isOpen, payload]);

  useEffect(
    () => () => {
      copiedResetRef.current?.();
    },
    []
  );

  const qr = useMemo(
    () => ({
      ios: encodeShareQr(iosStoreUrl),
      android: encodeShareQr(androidStoreUrl),
    }),
    [androidStoreUrl, iosStoreUrl]
  );

  const plan = useMemo(
    () => (activePayload ? planShareCards(activePayload, mode) : null),
    [activePayload, mode]
  );

  const safePageIndex = plan ? Math.min(pageIndex, plan.cards.length - 1) : 0;
  const activeSlice = plan?.cards[safePageIndex] ?? null;

  const buildRenderOptions = useCallback(
    (sliceIndex: number): ShareCardRenderOptions | null => {
      if (!plan) return null;
      const slice = plan.cards[sliceIndex];
      if (!slice) return null;
      const format = (value: number) => value.toLocaleString(locale);
      return {
        slice,
        sourceTitle,
        dateLabel,
        continuedLabel: slice.continuesToNext
          ? messages.chat_share_image_poster_continued({
              page: String(sliceIndex + 2).padStart(2, "0"),
            })
          : undefined,
        truncatedLabel: slice.truncatedEnd
          ? messages.chat_share_image_poster_truncated({
              shown: format(plan.shownChars),
              total: format(plan.totalChars),
            })
          : undefined,
        iosQr: qr.ios,
        androidQr: qr.android,
        fontFamily: clientFontFamily,
        scale: 3,
      };
    },
    [clientFontFamily, dateLabel, locale, messages, plan, qr, sourceTitle]
  );

  // Paint before the browser does, so a swapped-in card never shows a blank frame.
  useLayoutEffect(() => {
    if (!isOpen || !activeSlice) return;
    const canvas = previewCanvasRef.current;
    const renderOptions = buildRenderOptions(safePageIndex);
    if (!canvas || !renderOptions) return;
    renderShareCardToCanvas(canvas, renderOptions);
  }, [activeSlice, buildRenderOptions, isOpen, safePageIndex]);

  // Client sans font and Geist Mono may still be loading on first open; repaint once ready.
  useEffect(() => {
    if (!isOpen || typeof document === "undefined" || !document.fonts) return undefined;
    let cancelled = false;
    void Promise.all([
      document.fonts.load(`450 16px ${clientFontFamily}`),
      document.fonts.load('500 10px "Geist Mono"'),
    ]).then(() => {
      if (cancelled) return;
      const canvas = previewCanvasRef.current;
      const renderOptions = buildRenderOptions(safePageIndex);
      if (canvas && renderOptions) renderShareCardToCanvas(canvas, renderOptions);
    });
    return () => {
      cancelled = true;
    };
  }, [buildRenderOptions, clientFontFamily, isOpen, safePageIndex]);

  const beginSwap = useCallback((direction: CardSwap["direction"]) => {
    snapshotCard(previewCanvasRef.current, outgoingCanvasRef.current);
    setSwap((current) => ({ direction, phase: current?.phase === 0 ? 1 : 0 }));
  }, []);

  const handleModeChange = useCallback(
    (nextMode: ShareCardMode) => {
      if (nextMode === mode) return;
      beginSwap(nextMode === "pages" ? "next" : "prev");
      setMode(nextMode);
      setPageIndex(0);
      if (stageRef.current) stageRef.current.scrollTop = 0;
    },
    [beginSwap, mode]
  );

  const stepPage = useCallback(
    (delta: -1 | 1) => {
      if (!plan || plan.cards.length <= 1) return;
      const next = Math.min(Math.max(safePageIndex + delta, 0), plan.cards.length - 1);
      if (next === safePageIndex) return;
      beginSwap(delta > 0 ? "next" : "prev");
      setPageIndex(next);
      if (stageRef.current) stageRef.current.scrollTop = 0;
    },
    [beginSwap, plan, safePageIndex]
  );

  useEffect(() => {
    if (!isOpen || !plan || plan.cards.length <= 1) return undefined;
    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key === "ArrowLeft") {
        event.preventDefault();
        stepPage(-1);
      } else if (event.key === "ArrowRight") {
        event.preventDefault();
        stepPage(1);
      }
    };
    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, [isOpen, plan, stepPage]);

  const handleCopyImage = useCallback(async () => {
    const canvas = previewCanvasRef.current;
    if (!canvas) return;
    try {
      const blob = await canvasToPngBlob(canvas);
      await copyImageBlob(blob);
      setCopied(true);
      copiedResetRef.current?.();
      copiedResetRef.current = uiClock.after(1800, () => setCopied(false));
      toast.success(messages.chat_share_image_copied_toast(), {
        id: "share-image-copied",
        testId: "share-image-copied",
      });
    } catch {
      toast.error(messages.chat_share_image_copy_failed(), {
        id: "share-image-copy-failed",
        testId: "share-image-copy-failed",
      });
    }
  }, [messages]);

  const handleSaveCurrent = useCallback(async () => {
    const canvas = previewCanvasRef.current;
    if (!canvas || !plan || saving) return;
    setSaving(true);
    try {
      const blob = await canvasToPngBlob(canvas);
      await downloadFile(
        {
          fileName: shareFileName(dateLabel, safePageIndex, plan.cards.length),
          resolve: async () => blob,
        },
        { locale }
      );
    } catch {
      toast.error(messages.chat_share_image_save_failed(), {
        id: "share-image-save-failed",
        testId: "share-image-save-failed",
      });
    } finally {
      setSaving(false);
    }
  }, [dateLabel, locale, messages, plan, safePageIndex, saving]);

  const handleSaveAll = useCallback(async () => {
    if (!plan || plan.cards.length <= 1 || saving) return;
    setSaving(true);
    try {
      const offscreen = document.createElement("canvas");
      for (let i = 0; i < plan.cards.length; i += 1) {
        const renderOptions = buildRenderOptions(i);
        if (!renderOptions) continue;
        renderShareCardToCanvas(offscreen, renderOptions);
        const blob = await canvasToPngBlob(offscreen);
        await downloadFile(
          {
            fileName: shareFileName(dateLabel, i, plan.cards.length),
            resolve: async () => blob,
          },
          { locale }
        );
      }
    } catch {
      toast.error(messages.chat_share_image_save_failed(), {
        id: "share-image-save-failed",
        testId: "share-image-save-failed",
      });
    } finally {
      setSaving(false);
    }
  }, [buildRenderOptions, dateLabel, locale, messages, plan, saving]);

  if (!activePayload || !plan || !activeSlice) {
    return null;
  }

  const format = (value: number) => value.toLocaleString(locale);
  const cappedPageCount = Math.min(plan.totalPossiblePages, MAX_SHARE_PAGES);
  const lengthNotice = !plan.exceedsSingleLimit
    ? null
    : plan.mode === "excerpt"
      ? messages.chat_share_image_truncated_notice({
          shown: format(plan.shownChars),
          total: format(plan.totalChars),
        })
      : plan.wasTruncated
        ? messages.chat_share_image_pages_capped_notice({
            pages: String(plan.cards.length),
            shown: format(plan.shownChars),
            total: format(plan.totalChars),
          })
        : messages.chat_share_image_pages_notice({
            pages: String(plan.cards.length),
            total: format(plan.totalChars),
          });
  const isPaged = plan.cards.length > 1;
  const swapKey = swap ? `${swap.direction}-${swap.phase}` : undefined;

  return (
    <ModalOverlay
      className="comma-text-share-overlay"
      isDismissable
      isOpen={isOpen}
      onOpenChange={(open) => {
        if (!open) onClose();
      }}
    >
      <Modal className="comma-text-share-modal">
        <NativeSurfaceSuppressor />
        <RacDialog
          {...(lengthNotice ? { "aria-describedby": noticeId } : {})}
          aria-labelledby={titleId}
          className="comma-text-share-surface"
          data-testid="text-share-image-dialog"
        >
          {({ close }) => (
            <>
              <header className="comma-text-share-header">
                <div className="comma-text-share-header-row">
                  <h2
                    className="min-w-0 flex-1 truncate text-md font-semibold text-primary"
                    id={titleId}
                  >
                    {messages.chat_share_image_dialog_title()}
                  </h2>
                  <Button
                    aria-label={messages.common_close()}
                    className="comma-text-share-press -mr-xs shrink-0"
                    hierarchy="tertiary-gray"
                    iconLeading={<XIcon />}
                    iconOnly
                    onPress={close}
                    size="md"
                  />
                </div>
                {lengthNotice ? (
                  <p
                    className="text-xs font-regular text-quaternary tabular-nums"
                    data-testid="text-share-length-notice"
                    id={noticeId}
                  >
                    {lengthNotice}
                  </p>
                ) : null}
              </header>

              {plan.exceedsSingleLimit ? (
                <div
                  className="comma-text-share-length-bar"
                  data-testid="text-share-length-bar"
                >
                  <fieldset
                    aria-label={messages.chat_share_image_length_label()}
                    className="comma-text-share-segmented"
                    data-mode={mode}
                  >
                    <span aria-hidden className="comma-text-share-segmented-thumb" />
                    <button
                      aria-pressed={mode === "excerpt"}
                      className="comma-text-share-segment"
                      data-testid="text-share-mode-excerpt"
                      onClick={() => handleModeChange("excerpt")}
                      type="button"
                    >
                      {messages.chat_share_image_mode_excerpt()}
                    </button>
                    <button
                      aria-pressed={mode === "pages"}
                      className="comma-text-share-segment"
                      data-testid="text-share-mode-pages"
                      onClick={() => handleModeChange("pages")}
                      type="button"
                    >
                      {messages.chat_share_image_mode_pages({
                        count: String(cappedPageCount),
                      })}
                    </button>
                  </fieldset>
                </div>
              ) : null}

              <div className="comma-text-share-stage" ref={stageRef}>
                <div className="comma-text-share-desk">
                  <canvas
                    aria-hidden
                    className="comma-text-share-canvas"
                    data-role="outgoing"
                    data-swap={swapKey}
                    ref={outgoingCanvasRef}
                  />
                  <canvas
                    aria-label={messages.chat_share_image_dialog_title()}
                    className="comma-text-share-canvas"
                    data-role="current"
                    data-swap={swapKey}
                    data-testid="text-share-image-canvas"
                    ref={previewCanvasRef}
                  />
                </div>
              </div>

              <footer
                className="comma-text-share-footer"
                data-paged={isPaged ? "true" : "false"}
              >
                {isPaged ? (
                  <div
                    className="comma-text-share-pager"
                    data-testid="text-share-pager"
                  >
                    <Button
                      aria-label={messages.chat_share_image_prev_page()}
                      className="comma-text-share-press"
                      hierarchy="tertiary-gray"
                      iconLeading={<ChevronLeftSmallIcon />}
                      iconOnly
                      isDisabled={safePageIndex === 0}
                      onPress={() => stepPage(-1)}
                      size="xs"
                    />
                    <span
                      className="min-w-[7ch] text-center font-mono text-xs font-medium text-secondary tabular-nums"
                      data-testid="text-share-page-indicator"
                    >
                      {String(safePageIndex + 1).padStart(2, "0")} /{" "}
                      {String(plan.cards.length).padStart(2, "0")}
                    </span>
                    <Button
                      aria-label={messages.chat_share_image_next_page()}
                      className="comma-text-share-press"
                      hierarchy="tertiary-gray"
                      iconLeading={<ChevronRightSmallIcon />}
                      iconOnly
                      isDisabled={safePageIndex >= plan.cards.length - 1}
                      onPress={() => stepPage(1)}
                      size="xs"
                    />
                  </div>
                ) : null}

                <div className="comma-text-share-actions">
                  <Button
                    className="comma-text-share-press"
                    data-testid="text-share-copy-btn"
                    hierarchy="secondary-gray"
                    iconLeading={
                      <span aria-hidden className="comma-text-share-swap-stack">
                        <span data-active={copied ? "false" : "true"}>
                          <CopyIcon />
                        </span>
                        <span
                          className="text-success-primary"
                          data-active={copied ? "true" : "false"}
                        >
                          <CheckIcon />
                        </span>
                      </span>
                    }
                    onPress={() => void handleCopyImage()}
                    size="sm"
                  >
                    {/* Both labels share one cell so the button keeps its width. */}
                    <span className="comma-text-share-label-stack">
                      <span
                        aria-hidden={copied}
                        data-active={copied ? "false" : "true"}
                      >
                        {messages.chat_share_image_copy()}
                      </span>
                      <span
                        aria-hidden={!copied}
                        data-active={copied ? "true" : "false"}
                      >
                        {messages.chat_share_image_copied()}
                      </span>
                    </span>
                  </Button>

                  {isPaged ? (
                    <>
                      <Button
                        className="comma-text-share-press"
                        data-testid="text-share-save-page-btn"
                        hierarchy="secondary-gray"
                        iconLeading={<DownloadIcon />}
                        isDisabled={saving}
                        onPress={() => void handleSaveCurrent()}
                        size="sm"
                      >
                        {messages.chat_share_image_save_page({
                          page: String(safePageIndex + 1),
                        })}
                      </Button>
                      <Button
                        className="comma-text-share-press"
                        data-primary="true"
                        data-testid="text-share-save-all-btn"
                        hierarchy="primary"
                        iconLeading={<DownloadIcon />}
                        isDisabled={saving}
                        onPress={() => void handleSaveAll()}
                        size="sm"
                      >
                        {saving
                          ? messages.chat_share_image_saving()
                          : messages.chat_share_image_save_all({
                              count: String(plan.cards.length),
                            })}
                      </Button>
                    </>
                  ) : (
                    <Button
                      className="comma-text-share-press"
                      data-primary="true"
                      data-testid="text-share-save-btn"
                      hierarchy="primary"
                      iconLeading={<DownloadIcon />}
                      isDisabled={saving}
                      onPress={() => void handleSaveCurrent()}
                      size="sm"
                    >
                      {saving
                        ? messages.chat_share_image_saving()
                        : messages.chat_share_image_save()}
                    </Button>
                  )}
                </div>
              </footer>
            </>
          )}
        </RacDialog>
      </Modal>
    </ModalOverlay>
  );
}
