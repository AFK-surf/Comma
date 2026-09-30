import { formatNumber, type CommaLocale } from "@comma/i18n";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import {
  getNativeBridge,
  type AirDropState,
  type AirDropTransfer,
} from "@comma/native-bridge";
import { toast, type FileTransferToastProps } from "@comma/ui";
import { useEffect, useMemo, useRef, useState } from "react";

type CommaMessages = ReturnType<typeof useCommaMessages>;
type AirDropAct = (
  action: "accept" | "decline" | "dismiss" | "hold" | "release" | "reveal",
  requestId: string
) => void;

/**
 * Projects Main's AirDrop reception into this window's toast stack. Main owns
 * each card's lifetime: a transfer shows here only while Main keeps it and
 * only in the window whose chat receives the files.
 */
export function AirDropToasts() {
  const bridge = getNativeBridge();
  const isDesktop = bridge.platform === "electron";
  const messages = useCommaMessages();
  const locale = useCommaLocale();
  const [state, setState] = useState<AirDropState | null>(null);
  const raised = useRef(new Set<string>());
  const shown = useMemo(
    () =>
      state?.transfers.filter(
        (transfer) => transfer.surfaceId === bridge.self.windowId
      ) ?? [],
    [bridge, state]
  );
  const previewUrls = useAirDropPreviewUrls(shown);

  useEffect(() => {
    if (!isDesktop) return;
    return bridge.airDrop.state.subscribe((snapshot) => {
      setState((current) =>
        current && current.revision > snapshot.revision ? current : snapshot
      );
    });
  }, [bridge, isDesktop]);

  useEffect(() => {
    if (!state) return;
    const act: AirDropAct = (action, requestId) => {
      void bridge.airDrop.act({ action, requestId }).catch(() => undefined);
    };
    const ids = new Set(shown.map((transfer) => airDropToastId(transfer.requestId)));
    for (const id of raised.current) {
      if (ids.has(id)) continue;
      raised.current.delete(id);
      toast.dismiss(id);
    }
    for (const transfer of shown) {
      const id = airDropToastId(transfer.requestId);
      raised.current.add(id);
      toast.fileTransfer({
        id,
        testId: id,
        ...airDropToastProps(transfer, {
          act,
          locale,
          messages,
          previewUrl: (index) => previewUrls.get(previewKey(transfer.requestId, index)),
        }),
      });
    }
  }, [bridge, locale, messages, previewUrls, shown, state]);

  useEffect(
    () => () => {
      for (const id of raised.current) toast.dismiss(id);
      raised.current.clear();
    },
    []
  );

  return null;
}

export function airDropToastId(requestId: string) {
  return `comma-airdrop-${requestId}`;
}

function previewKey(requestId: string, index: number) {
  return `${requestId}:${index}`;
}

/**
 * Object URLs for the previews Main rendered, fetched over the binary preview
 * command. Each URL lives until its transfer leaves this window's state.
 */
function useAirDropPreviewUrls(transfers: readonly AirDropTransfer[]) {
  const bridge = getNativeBridge();
  const [urls, setUrls] = useState<ReadonlyMap<string, string>>(() => new Map());
  const owned = useRef(new Map<string, string>());
  const requested = useRef(new Set<string>());
  const wanted = transfers
    .flatMap((transfer) =>
      transfer.files.flatMap((file, index) =>
        file.preview ? [previewKey(transfer.requestId, index)] : []
      )
    )
    .join(" ");

  useEffect(() => {
    const keys = new Set(wanted ? wanted.split(" ") : []);
    let released = false;
    for (const [key, url] of owned.current) {
      if (keys.has(key)) continue;
      URL.revokeObjectURL(url);
      owned.current.delete(key);
      released = true;
    }
    for (const key of requested.current)
      if (!keys.has(key)) requested.current.delete(key);
    if (released) setUrls(new Map(owned.current));
    for (const key of keys) {
      if (requested.current.has(key)) continue;
      requested.current.add(key);
      const [requestId = "", index = "0"] = key.split(":");
      void bridge.airDrop
        .preview({ index: Number(index), requestId })
        .then((result) => {
          if (result.status !== "ready" || !requested.current.has(key)) return;
          if (owned.current.has(key)) return;
          owned.current.set(
            key,
            URL.createObjectURL(
              new Blob([Uint8Array.from(result.image)], { type: result.mediaType })
            )
          );
          setUrls(new Map(owned.current));
        })
        .catch(() => undefined);
    }
  }, [bridge, wanted]);

  useEffect(
    () => () => {
      for (const url of owned.current.values()) URL.revokeObjectURL(url);
      owned.current.clear();
      requested.current.clear();
    },
    []
  );

  return urls;
}

export function airDropToastProps(
  transfer: AirDropTransfer,
  {
    act,
    locale,
    messages,
    previewUrl,
  }: {
    act: AirDropAct;
    locale: CommaLocale;
    messages: CommaMessages;
    previewUrl: (index: number) => string | undefined;
  }
): FileTransferToastProps {
  const { requestId } = transfer;
  const sender = transfer.senderName ?? messages.airdrop_unknown_sender();
  const chat = transfer.chatTitle ?? "";
  const files = transfer.files.map((file, index) => {
    const src = file.preview && previewUrl(index);
    return {
      kind: file.kind,
      name: file.name,
      ...(file.preview && src
        ? { preview: { height: file.preview.height, src, width: file.preview.width } }
        : {}),
    };
  });
  const dismiss = () => act("dismiss", requestId);
  // Main keeps a result on screen while the user reads or scrolls it.
  const onHoldChange = (held: boolean) => act(held ? "hold" : "release", requestId);
  const reveal = transfer.canReveal
    ? [{ label: messages.airdrop_reveal(), onPress: () => act("reveal", requestId) }]
    : [];

  switch (transfer.phase) {
    case "offer":
      return {
        actions: [
          { label: messages.airdrop_accept(), onPress: () => act("accept", requestId) },
          {
            hierarchy: "tertiary-gray",
            label: messages.airdrop_decline(),
            onPress: () => act("decline", requestId),
          },
        ],
        description: messages.airdrop_chat_destination({ chat }),
        files,
        onClose: dismiss,
        onHoldChange,
        status: "offer",
        title: messages.airdrop_offer_title({ sender }),
      };
    case "receiving":
      return {
        description: messages.airdrop_chat_destination({ chat }),
        files,
        onHoldChange,
        ...(transfer.progress === undefined ? {} : { progress: transfer.progress }),
        status: "progress",
        title: messages.airdrop_receiving_title({ sender }),
      };
    case "completed":
      return {
        actions: reveal,
        ...(transfer.unattachedCount
          ? {
              description: messages.airdrop_completed_unattached({
                count: transfer.unattachedCount,
                formattedCount: formatNumber(transfer.unattachedCount, locale),
              }),
            }
          : {}),
        files,
        onClose: dismiss,
        onHoldChange,
        status: "success",
        title: messages.airdrop_completed_title({ chat }),
      };
    case "failed":
      return {
        actions: reveal,
        description:
          transfer.failure === "no_chat"
            ? messages.airdrop_failed_no_chat()
            : transfer.failure === "directory"
              ? messages.airdrop_failed_directory()
              : transfer.failure === "attach"
                ? messages.airdrop_failed_attach()
                : messages.airdrop_failed_transfer(),
        files: [],
        onClose: dismiss,
        onHoldChange,
        status: "error",
        title: messages.airdrop_failed_title(),
      };
  }
}
