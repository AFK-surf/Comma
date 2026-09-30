import { messages, type CommaLocale } from "@comma/i18n";
import {
  fileDownloadMaxBytes,
  getNativeBridge,
  type CommaNativeBridge,
  type FilesSaveDownloadResult,
} from "@comma/native-bridge";
import type { ChatPanelFileOpenInAction } from "@comma/ui";
import type { CommaApiClient } from "../api";
import type { ChatRegistryAttempt } from "../components/chat/ChatProvider";
import {
  conversationFileSourceKey,
  resolveConversationFile,
  type ConversationFileSource,
} from "./fileSources";
import { revealLabel } from "./fileDownloads";

type SavedFile = Extract<FilesSaveDownloadResult, { status: "saved" }>;
type Attempt = Pick<ChatRegistryAttempt, "signal" | "isCurrent" | "release">;
type ReceiptStore = Map<string, SavedFile>;
const maxSavedReceipts = 32;
const receiptStores = new WeakMap<object, ReceiptStore>();

const abortError = () => new DOMException("File action cancelled", "AbortError");

/** Native effects are never replayed automatically. See tla/file-actions/FileAction.tla. */
export function createFileOpenInAction({
  api,
  source,
  bridge = getNativeBridge(),
  locale,
  beginAttempt,
}: {
  api: CommaApiClient;
  source: ConversationFileSource;
  bridge?: Pick<CommaNativeBridge, "files" | "os" | "platform">;
  locale: CommaLocale;
  beginAttempt: () => Attempt;
}): ChatPanelFileOpenInAction | undefined {
  return createResolvedFileOpenInAction({
    owner: api,
    sourceKey: conversationFileSourceKey(source),
    fileName: source.fileName,
    resolveBytes: (signal) => resolveConversationFile(api, source, signal),
    bridge,
    locale,
    beginAttempt,
  });
}

/** Adapters supply their existing byte owner; this layer never interprets source identity. */
export function createResolvedFileOpenInAction({
  owner,
  sourceKey,
  fileName,
  resolveBytes,
  bridge,
  locale,
  beginAttempt,
}: {
  owner: object;
  sourceKey: string;
  fileName: string;
  resolveBytes: (signal: AbortSignal) => Promise<Blob>;
  bridge: Pick<CommaNativeBridge, "files" | "os" | "platform">;
  locale: CommaLocale;
  beginAttempt: () => Attempt;
}): ChatPanelFileOpenInAction | undefined {
  if (bridge.platform !== "electron" || bridge.os !== "macos") return undefined;
  let receipts = receiptStores.get(owner);
  if (!receipts) {
    receipts = new Map();
    receiptStores.set(owner, receipts);
  }
  const store = receipts;
  const key = sourceKey;

  const run = async (
    effect: (saved: SavedFile) => Promise<boolean>,
    signal?: AbortSignal
  ) => {
    const attempt = beginAttempt();
    const operationSignal = signal
      ? AbortSignal.any([signal, attempt.signal])
      : attempt.signal;
    const assertCurrent = () => {
      if (operationSignal.aborted || !attempt.isCurrent()) throw abortError();
    };
    try {
      assertCurrent();
      let receipt = store.get(key);
      if (!receipt) {
        const blob = await resolveBytes(operationSignal);
        assertCurrent();
        if (blob.size > fileDownloadMaxBytes)
          throw new Error(
            messages.file_download_too_large_description(
              { fileName: fileName },
              { locale }
            )
          );
        const content = new Uint8Array(await blob.arrayBuffer());
        assertCurrent();
        const result = await bridge.files.saveDownload({
          content,
          fileName: fileName,
        });
        if (result.status !== "saved")
          throw new Error(
            messages.file_download_failed_description(
              { fileName: fileName },
              { locale }
            )
          );
        receipt = result;
      }
      // Only completed saves are reusable. Independent simultaneous requests
      // may save separate files; neither owns the other's cancellation.
      store.delete(key);
      store.set(key, receipt);
      while (store.size > maxSavedReceipts) store.delete(store.keys().next().value!);
      assertCurrent();
      if (!(await effect(receipt))) {
        if (store.get(key) === receipt) store.delete(key);
        throw new Error(
          messages.file_download_open_failed_description(
            { fileName: receipt.fileName },
            { locale }
          )
        );
      }
    } finally {
      attempt.release();
    }
  };

  return {
    listApplications: async (signal) => {
      if (signal?.aborted) throw abortError();
      const result = await bridge.files.listOpenApplications({
        fileName: fileName,
      });
      if (signal?.aborted) throw abortError();
      if (result.status !== "available")
        throw new Error(messages.ui_file_open_in_failed(undefined, { locale }));
      return result.applications.map(({ id, name, isDefault, iconDataUrl }) => ({
        id,
        name,
        isDefault,
        ...(iconDataUrl ? { iconDataUrl } : {}),
      }));
    },
    openApplication: (applicationId, signal) =>
      run(
        async ({ downloadRef }) =>
          (await bridge.files.openDownload({ downloadRef, applicationId })).status ===
          "opened",
        signal
      ),
    reveal: {
      label: revealLabel(bridge.os, locale),
      run: (signal) =>
        run(
          async ({ downloadRef }) =>
            (await bridge.files.revealDownload({ downloadRef })).status === "revealed",
          signal
        ),
    },
  };
}
