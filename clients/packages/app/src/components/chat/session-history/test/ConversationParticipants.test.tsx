import { CommaI18nProvider } from "@comma/i18n/react";
import { initializeCommaI18n } from "@comma/i18n";
import { defaultCommaClientSettings } from "@comma/native-bridge";
import { render } from "@comma/test-utils/render";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { ChatParticipantStatus } from "@comma/core/chat";
import { ConversationParticipants } from "../SessionHistory";

vi.mock("../../ChatProvider", () => ({
  useChatProductLease: () => ({}),
}));

vi.mock("../../../commaClientSettings", () => ({
  useCommaClientSettings: () => ({
    settings: { ...defaultCommaClientSettings, sessionHistoryEnabled: true },
    update: vi.fn(),
  }),
}));

const baseRouter: ChatParticipantStatus = {
  actorId: "actor_router",
  actorRole: "router",
  conversationId: "cnv_home",
  name: "Comma",
  participantId: "ptp_router",
  state: "stopped",
  status: "",
  updatedAt: 1,
};

function renderParticipants(participants: ChatParticipantStatus[]) {
  return render(
    <CommaI18nProvider locale="en">
      <ConversationParticipants
        groupId="grp_1"
        participants={participants}
        onOpen={vi.fn()}
      />
    </CommaI18nProvider>
  );
}

beforeEach(() => {
  initializeCommaI18n(["en"]);
});

afterEach(() => {
  initializeCommaI18n(["en"]);
});

describe("ConversationParticipants", () => {
  it.each<[string, Partial<ChatParticipantStatus>]>([
    ["stopped", { state: "stopped" }],
    ["error", { state: "error", status: "Runtime unavailable" }],
    ["waiting on delegated tasks", { state: "active", waiting: true }],
    ["background loop wake", { state: "active", loopWake: true }],
  ])("pauses the Router logo when the participant is %s", (_label, patch) => {
    const view = renderParticipants([{ ...baseRouter, ...patch }]);
    const logo = view.container.querySelector('[data-slot="comma-logo-animation"]');
    expect(logo).toHaveAttribute("data-paused", "true");
  });

  it("animates the Router logo only while the participant is actively working", () => {
    const view = renderParticipants([
      { ...baseRouter, state: "active", status: "is thinking..." },
    ]);
    const logo = view.container.querySelector('[data-slot="comma-logo-animation"]');
    expect(logo).toHaveAttribute("data-paused", "false");

    view.rerender(
      <CommaI18nProvider locale="en">
        <ConversationParticipants
          groupId="grp_1"
          participants={[{ ...baseRouter, state: "stopped", status: "" }]}
          onOpen={vi.fn()}
        />
      </CommaI18nProvider>
    );
    expect(logo).toHaveAttribute("data-paused", "true");
  });
});
