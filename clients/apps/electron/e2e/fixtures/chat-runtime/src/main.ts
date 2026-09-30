import { getNativeBridge } from "@comma/native-bridge";
import {
  sessionExpectation,
  sessionProductLease,
  type SessionProductLease,
} from "@comma/session-contract";
import { BridgeConversationChannel } from "../../../../../../packages/app/src/runtime-chat/channel/BridgeConversationChannel";

const delayedFilename = "delayed-runtime.txt";
const shouldDeferFirstRetain = new URLSearchParams(location.search).has(
  "defer-first-retain"
);
const shouldStubPickAttachments = new URLSearchParams(location.search).has(
  "stub-pick-attachments"
);
const shouldDeferFirstIntakeAck = new URLSearchParams(location.search).has(
  "defer-first-intake-ack"
);
const originalBridge = getNativeBridge();
const originalChat = originalBridge.chat;
const originalLocalFiles = originalBridge.localFiles;
const shouldOwnFixtureChannel = originalBridge.self.role === "main-window";
const beginSendIntentInputs: Record<string, unknown>[] = [];
const intakeAckInputs: Record<string, unknown>[] = [];
const pickAttachmentInputs: Parameters<typeof originalChat.pickAttachments>[0][] = [];
const clearPresentationInputs: Record<string, unknown>[] = [];
const retainInputs: Record<string, unknown>[] = [];
const releaseInputs: Record<string, unknown>[] = [];
let completedReleaseCount = 0;
const setDraftInputs: Record<string, unknown>[] = [];
let firstRetainAcceptedByMain = false;
let firstIntakeAckPending = false;
let releaseFirstIntakeAck: (() => void) | undefined;
const firstIntakeAckGate = new Promise<void>((resolve) => {
  releaseFirstIntakeAck = resolve;
});
let releaseFirstRetainReceipt: (() => void) | undefined;
const firstRetainReceiptGate = new Promise<void>((resolve) => {
  releaseFirstRetainReceipt = resolve;
});
let retainSequence = 0;
let releaseFileRead: (() => void) | undefined;
let staleDraftState: "idle" | "pending" | "rejected" | "resolved" = "idle";
let activeProductLease = await loadProductLease();

globalThis.commaNative = {
  ...originalBridge,
  chat: {
    ...originalChat,
    beginSendIntent: async (input) => {
      const receipt = await originalChat.beginSendIntent(input);
      // Record only completed Main reservations so an E2E edit can be placed
      // deterministically after the click-time linearization point.
      beginSendIntentInputs.push({ ...input });
      return receipt;
    },
    acknowledgeIntakeFailures: async (input) => {
      intakeAckInputs.push({ ...input });
      if (shouldDeferFirstIntakeAck && intakeAckInputs.length === 1) {
        firstIntakeAckPending = true;
        await firstIntakeAckGate;
        firstIntakeAckPending = false;
      }
      return originalChat.acknowledgeIntakeFailures(input);
    },
    clearPresentation: async (input) => {
      clearPresentationInputs.push({ ...input });
      return originalChat.clearPresentation(input);
    },
    release: async (input) => {
      releaseInputs.push({ ...input });
      const receipt = await originalChat.release(input);
      completedReleaseCount += 1;
      return receipt;
    },
    retain: async (input) => {
      retainInputs.push({ ...input });
      const sequence = ++retainSequence;
      const receipt = await originalChat.retain(input);
      if (shouldDeferFirstRetain && sequence === 1) {
        firstRetainAcceptedByMain = true;
        await firstRetainReceiptGate;
      }
      return receipt;
    },
    setDraft: async (input) => {
      setDraftInputs.push({ ...input });
      return originalChat.setDraft(input);
    },
    pickAttachments: async (input) => {
      pickAttachmentInputs.push({ ...input });
      if (input.files?.some((file) => file.name === delayedFilename)) {
        await new Promise<void>((resolve) => {
          releaseFileRead = () => {
            releaseFileRead = undefined;
            resolve();
          };
        });
      }
      if (!shouldStubPickAttachments) {
        return originalChat.pickAttachments(input);
      }

      // With ?stub-pick-attachments=1, Main's real native dialog is bypassed
      // and its Main-side effect is emulated by attaching the fixture's opaque
      // local-index ref through the real leased attach owner. Tests that drive
      // the real dialog (via an Electron dialog override) omit the parameter.
      const {
        maxFiles: _maxFiles,
        maxTotalSize: _maxTotalSize,
        maxUploadFiles: _maxUploadFiles,
        ...target
      } = input;
      const receipt = await originalChat.attachLocalFiles({
        ...target,
        files: [
          {
            localFileRef: `lfi1_${"e".repeat(43)}`,
            mediaType: "text/plain",
            name: "fixture-local-index.txt",
            size: 7,
          },
        ],
      });
      return {
        cancelled: false,
        errors: [],
        intakeId: "fixture-local-index-intake",
        revision: receipt.revision,
      };
    },
  },
  localFiles: {
    ...originalLocalFiles,
    pick: async () => ({
      cancelled: false,
      errors: [],
      files: [
        {
          localFileRef: `lfi1_${"e".repeat(43)}`,
          mediaType: "text/plain",
          name: "fixture-local-index.txt",
          size: 7,
        },
      ],
    }),
  },
};

let channel = createChannel();
const attachmentInput = requiredElement<HTMLInputElement>("attachment");
const promptInput = requiredElement<HTMLInputElement>("prompt");
const pickLocalButton = requiredElement<HTMLButtonElement>("pick-local");
const sendButton = requiredElement<HTMLButtonElement>("send");
const sendState = requiredElement<HTMLOutputElement>("send-state");
const snapshot = requiredElement<HTMLPreElement>("snapshot");

channel.subscribe(renderSnapshot);
if (shouldOwnFixtureChannel) channel.start();
renderSnapshot();

attachmentInput.addEventListener("change", () => {
  const files = Array.from(attachmentInput.files ?? []);
  channel.attachFiles(
    files.map((file) => ({ data: file, name: file.name, size: file.size }))
  );
  attachmentInput.value = "";
});

pickLocalButton.addEventListener("click", () => {
  void Promise.resolve(channel.pickAttachments?.());
});

promptInput.addEventListener("input", () => {
  channel.setDraft(promptInput.value);
});

sendButton.addEventListener("click", () => {
  sendState.value = "pending";
  Promise.resolve(channel.send(promptInput.value)).then(
    () => {
      sendState.value = "resolved";
    },
    (error: unknown) => {
      sendState.value = `rejected: ${error instanceof Error ? error.message : String(error)}`;
    }
  );
});

window.chatRuntimeFixture = {
  completedReleaseCount: () => completedReleaseCount,
  bridgeCalls: () => ({
    beginSendIntents: beginSendIntentInputs,
    clearPresentations: clearPresentationInputs,
    intakeAcks: intakeAckInputs,
    picks: pickAttachmentInputs,
    releases: releaseInputs,
    retains: retainInputs,
    setDrafts: setDraftInputs,
  }),
  clearPresentation: () => channel.clearPresentation(),
  getSnapshot: () => channel.getSnapshot(),
  hasDelayedFileRead: () => Boolean(releaseFileRead),
  isFirstRetainAcceptedByMain: () => firstRetainAcceptedByMain,
  isFirstIntakeAckPending: () => firstIntakeAckPending,
  pickLocalThroughNative: async () => {
    const fixtureBridge = getNativeBridge();
    globalThis.commaNative = {
      ...fixtureBridge,
      localFiles: originalLocalFiles,
    };
    try {
      await channel.pickAttachments?.();
    } finally {
      globalThis.commaNative = fixtureBridge;
    }
  },
  pickLocalAgainThroughNative: async () => {
    const input = pickAttachmentInputs.at(-1);
    if (!input) {
      throw new Error("The fixture has not observed an attachment intake.");
    }
    return originalChat.pickAttachments(input);
  },
  pickLocalForWorkspace: (workspaceId) =>
    originalLocalFiles.pick({
      maxFiles: 50,
      maxTotalSize: 1024 * 1024 * 1024,
      session: activeProductLease,
      workspaceId,
    }),
  previewLocal: async (localFileRef) => {
    const preview = await channel.previewLocalFile?.(localFileRef);
    if (!preview) return undefined;
    try {
      return await decodePreviewImage(preview.url);
    } finally {
      preview.release();
    }
  },
  previewLocalThroughNative: async (localFileRef) => {
    const result = await originalLocalFiles.preview({
      localFileRef,
      session: activeProductLease,
    });
    if (result.status === "unavailable") return result;

    const pngImage = Uint8Array.from(result.pngImage);
    const url = URL.createObjectURL(new Blob([pngImage.buffer], { type: "image/png" }));
    try {
      return {
        status: "ready" as const,
        ...(await decodePreviewImage(url)),
      };
    } finally {
      URL.revokeObjectURL(url);
    }
  },
  queueStaleDraftAndStop: () => {
    staleDraftState = "pending";
    void Promise.resolve(channel.setDraft("account A private draft")).then(
      () => {
        staleDraftState = "resolved";
      },
      () => {
        staleDraftState = "rejected";
      }
    );
    channel.stop();
  },
  releaseFirstIntakeAck: () => {
    if (!releaseFirstIntakeAck) {
      throw new Error("The delayed intake acknowledgement has already been released.");
    }
    const release = releaseFirstIntakeAck;
    releaseFirstIntakeAck = undefined;
    release();
  },
  releaseFileRead: () => {
    if (!releaseFileRead) {
      throw new Error("The delayed File.arrayBuffer() read has not started.");
    }
    releaseFileRead();
  },
  releaseFirstRetainReceipt: () => {
    if (!releaseFirstRetainReceipt) {
      throw new Error("The delayed retain receipt has already been released.");
    }
    const release = releaseFirstRetainReceipt;
    releaseFirstRetainReceipt = undefined;
    release();
  },
  replaceSession: async () => {
    const current = await originalBridge.session.state.get();
    if (current.phase !== "signed_in") {
      throw new Error("The replacement fixture requires an active Session.");
    }
    const signedOut = await originalBridge.session.signOut({
      expected: sessionExpectation(current),
    });
    if (!signedOut.ok) {
      throw new Error(`Session sign-out failed: ${signedOut.error.code}`);
    }
    const challenge = await originalBridge.session.requestEmailLogin({
      email: "runtime-b@comma.local",
      expected: sessionExpectation(signedOut.value),
    });
    if (!challenge.ok) {
      throw new Error(`Session login request failed: ${challenge.error.code}`);
    }
    const verified = await originalBridge.session.verifyEmailLogin({
      attempt: challenge.value.attempt,
      challengeId: challenge.value.challengeId,
      code: "654321",
    });
    if (!verified.ok) {
      throw new Error(`Session verification failed: ${verified.error.code}`);
    }
    activeProductLease = requireProductLease(verified.value);
  },
  sendCurrent: (text) => channel.send(text),
  sendCurrentAccepted: (text) => channel.send(text).accepted,
  removeAttachment: (attachmentId) => channel.removeAttachment(attachmentId),
  staleDraftOutcome: () => staleDraftState,
  startReplacementChannel: () => {
    channel = createChannel();
    channel.subscribe(renderSnapshot);
    channel.start();
    renderSnapshot();
  },
  stopChannel: () => channel.stop(),
};

window.addEventListener("beforeunload", () => {
  if (shouldOwnFixtureChannel) channel.stop();
});

function renderSnapshot() {
  snapshot.textContent = JSON.stringify(channel.getSnapshot(), undefined, 2);
}

function createChannel() {
  return new BridgeConversationChannel({
    conversationId: "cnv-public-runtime-b",
    groupId: "grp1_1720000000000000003_1720000000000000004",
    session: activeProductLease,
    workspaceId: "ws-runtime-b",
  });
}

function requireProductLease(
  lifecycle: Parameters<typeof sessionProductLease>[0]
): SessionProductLease {
  const lease = sessionProductLease(lifecycle);
  if (!lease) {
    throw new Error("The Chat ownership fixture requires a signed-in Session.");
  }
  return lease;
}

async function loadProductLease(): Promise<SessionProductLease> {
  const current = await originalBridge.session.state.get();
  if (current.phase === "signed_in") {
    return requireProductLease(current);
  }
  const reconciled = await originalBridge.session.reconcile({
    reason: "startup",
  });
  if (!reconciled.ok) {
    throw new Error(`Session startup reconcile failed: ${reconciled.error.code}`);
  }
  return requireProductLease(reconciled.value);
}

function requiredElement<T extends HTMLElement>(id: string) {
  const element = document.getElementById(id);
  if (!element) throw new Error(`Missing fixture element #${id}.`);
  return element as T;
}

async function decodePreviewImage(url: string) {
  const image = new Image();
  image.src = url;
  await image.decode();
  return {
    height: image.naturalHeight,
    url,
    width: image.naturalWidth,
  };
}

declare global {
  interface Window {
    chatRuntimeFixture: {
      completedReleaseCount: () => number;
      bridgeCalls: () => {
        beginSendIntents: Record<string, unknown>[];
        clearPresentations: Record<string, unknown>[];
        intakeAcks: Record<string, unknown>[];
        picks: Record<string, unknown>[];
        releases: Record<string, unknown>[];
        retains: Record<string, unknown>[];
        setDrafts: Record<string, unknown>[];
      };
      clearPresentation: () => unknown;
      getSnapshot: () => ReturnType<BridgeConversationChannel["getSnapshot"]>;
      hasDelayedFileRead: () => boolean;
      isFirstRetainAcceptedByMain: () => boolean;
      isFirstIntakeAckPending: () => boolean;
      pickLocalAgainThroughNative: () => ReturnType<
        typeof originalChat.pickAttachments
      >;
      pickLocalForWorkspace: (
        workspaceId: string
      ) => ReturnType<typeof originalLocalFiles.pick>;
      pickLocalThroughNative: () => Promise<void>;
      previewLocal: (localFileRef: string) => Promise<
        | {
            height: number;
            url: string;
            width: number;
          }
        | undefined
      >;
      previewLocalThroughNative: (localFileRef: string) => Promise<
        | { status: "unavailable" }
        | {
            height: number;
            status: "ready";
            url: string;
            width: number;
          }
      >;
      queueStaleDraftAndStop: () => void;
      releaseFirstIntakeAck: () => void;
      releaseFileRead: () => void;
      releaseFirstRetainReceipt: () => void;
      replaceSession: () => Promise<void>;
      sendCurrent: (text: string) => unknown;
      sendCurrentAccepted: (text: string) => Promise<void>;
      removeAttachment: (attachmentId: string) => void;
      staleDraftOutcome: () => "idle" | "pending" | "rejected" | "resolved";
      startReplacementChannel: () => void;
      stopChannel: () => void;
    };
  }
}
