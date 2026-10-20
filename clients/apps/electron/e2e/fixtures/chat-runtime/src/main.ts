import { baseLocale } from "@comma/i18n";
import { getNativeBridge } from "@comma/native-bridge";
import { sessionProductLease, type SessionProductLease } from "@comma/session-contract";
import { CoreConversationChannel } from "../../../../../../packages/app/src/components/chat/channel/CoreConversationChannel";
import { CoreClient, electronCoreOpener } from "@comma/core-client";

const bridge = getNativeBridge();
// The client core: it runs the session (Main keeps the bearer) and the window's chat.
const core = new CoreClient(electronCoreOpener(() => bridge.core.open()));
const productLease = await loadProductLease();

// The window's channel as the app has it: the core's view of the conversation, Main's reading of dropped files.
const channel = new CoreConversationChannel({
  bridge,
  client: core,
  conversationId: "cnv-public-runtime-b",
  groupId: "grp1_1720000000000000003_1720000000000000004",
  locale: baseLocale,
  session: productLease,
  workspaceId: "ws-runtime-b",
});
const attachmentInput = requiredElement<HTMLInputElement>("attachment");
const promptInput = requiredElement<HTMLInputElement>("prompt");
const pickLocalButton = requiredElement<HTMLButtonElement>("pick-local");
const sendButton = requiredElement<HTMLButtonElement>("send");
const sendState = requiredElement<HTMLOutputElement>("send-state");
const snapshot = requiredElement<HTMLPreElement>("snapshot");

channel.subscribe(renderSnapshot);
if (bridge.self.role === "main-window") channel.start();
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
  getSnapshot: () => channel.getSnapshot(),
  pickLocalForWorkspace: (workspaceId) =>
    bridge.localFiles.pick({
      maxFiles: 50,
      maxTotalSize: 1024 * 1024 * 1024,
      session: productLease,
      workspaceId,
    }),
};

window.addEventListener("beforeunload", () => channel.stop());

function renderSnapshot() {
  snapshot.textContent = JSON.stringify(channel.getSnapshot(), undefined, 2);
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

/** The lease Main's gate holds once the core's startup probe confirmed the seeded session. */
async function loadProductLease(): Promise<SessionProductLease> {
  const now = await bridge.session.state.get();
  if (now.phase === "signed_in") return requireProductLease(now);
  return new Promise((resolve, reject) => {
    const stop = bridge.session.state.subscribe((current) => {
      if (current.phase === "initializing" || current.phase === "authenticating")
        return;
      queueMicrotask(() => stop());
      if (current.phase === "signed_in") resolve(requireProductLease(current));
      else
        reject(
          new Error(`The Chat ownership fixture found the session ${current.phase}.`)
        );
    });
  });
}

function requiredElement<T extends HTMLElement>(id: string) {
  const element = document.getElementById(id);
  if (!element) throw new Error(`Missing fixture element #${id}.`);
  return element as T;
}

declare global {
  interface Window {
    chatRuntimeFixture: {
      getSnapshot: () => ReturnType<CoreConversationChannel["getSnapshot"]>;
      pickLocalForWorkspace: (
        workspaceId: string
      ) => ReturnType<ReturnType<typeof getNativeBridge>["localFiles"]["pick"]>;
    };
  }
}
