import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import { uiClock, type CancelUiTimer } from "@comma/ui/clock";
import { Button } from "@comma/ui/components/Button";
import { CheckIcon, CopyIcon, DownloadIcon, XIcon } from "@comma/ui/components/icons";
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
  planShareCard,
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

function canvasToPngBlob(canvas: HTMLCanvasElement): Promise<Blob> {
  return new Promise((resolve, reject) => {
    canvas.toBlob((blob) => {
      if (blob) resolve(blob);
      else reject(new Error("PNG encode failed"));
    }, "image/png");
  });
}

function shareFileName(dateLabel: string): string {
  const stamp = dateLabel.replace(/\./g, "");
  return `comma-share-${stamp}.png`;
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

  // Hold the last payload through the exit animation so the card stays on
  // screen until the dialog has left.
  const [retainedPayload, setRetainedPayload] =
    useState<ChatSelectionSharePayload | null>(payload);
  useEffect(() => {
    if (payload) setRetainedPayload(payload);
  }, [payload]);

  const activePayload = payload ?? retainedPayload;

  const [copied, setCopied] = useState(false);
  const [saving, setSaving] = useState(false);
  const [dateLabel, setDateLabel] = useState(() => formatSwissDate(uiClock.now()));
  const [clientFontFamily, setClientFontFamily] = useState(() =>
    resolveShareCardFontFamily()
  );

  const previewCanvasRef = useRef<HTMLCanvasElement | null>(null);
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

  useEffect(() => {
    if (isOpen && payload) {
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

  const slice = useMemo(
    () => (activePayload ? planShareCard(activePayload) : null),
    [activePayload]
  );

  const renderOptions = useMemo<ShareCardRenderOptions | null>(() => {
    if (!slice) return null;
    return {
      slice,
      sourceTitle,
      dateLabel,
      iosQr: qr.ios,
      androidQr: qr.android,
      fontFamily: clientFontFamily,
      scale: 3,
    };
  }, [clientFontFamily, dateLabel, qr, slice, sourceTitle]);

  // Paint before the browser's first frame so the card enters in sync with the modal.
  useLayoutEffect(() => {
    if (!isOpen || !renderOptions) return;
    const canvas = previewCanvasRef.current;
    if (!canvas) return;
    renderShareCardToCanvas(canvas, renderOptions);
  }, [isOpen, renderOptions]);

  // Client sans font and Geist Mono may still be loading on first open; repaint once ready.
  useEffect(() => {
    if (!isOpen || !renderOptions || typeof document === "undefined" || !document.fonts)
      return undefined;
    let cancelled = false;
    void Promise.all([
      document.fonts.load(`450 16px ${clientFontFamily}`),
      document.fonts.load('500 10px "Geist Mono"'),
    ]).then(() => {
      if (cancelled) return;
      const canvas = previewCanvasRef.current;
      if (canvas) renderShareCardToCanvas(canvas, renderOptions);
    });
    return () => {
      cancelled = true;
    };
  }, [clientFontFamily, isOpen, renderOptions]);

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

  const handleSave = useCallback(async () => {
    const canvas = previewCanvasRef.current;
    if (!canvas || saving) return;
    setSaving(true);
    try {
      const blob = await canvasToPngBlob(canvas);
      await downloadFile(
        {
          fileName: shareFileName(dateLabel),
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
  }, [dateLabel, locale, messages, saving]);

  if (!activePayload || !slice) {
    return null;
  }

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
              </header>

              <div className="comma-text-share-stage">
                <div className="comma-text-share-desk">
                  <canvas
                    aria-label={messages.chat_share_image_dialog_title()}
                    className="comma-text-share-canvas"
                    data-testid="text-share-image-canvas"
                    ref={previewCanvasRef}
                  />
                </div>
              </div>

              <footer className="comma-text-share-footer">
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

                  <Button
                    className="comma-text-share-press"
                    data-primary="true"
                    data-testid="text-share-save-btn"
                    hierarchy="primary"
                    iconLeading={<DownloadIcon />}
                    isDisabled={saving}
                    onPress={() => void handleSave()}
                    size="sm"
                  >
                    {saving
                      ? messages.chat_share_image_saving()
                      : messages.chat_share_image_save()}
                  </Button>
                </div>
              </footer>
            </>
          )}
        </RacDialog>
      </Modal>
    </ModalOverlay>
  );
}
