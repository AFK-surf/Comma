import { describe, expect, it } from "vitest";
import type { ChatMessage } from "../conversationChannel";
import {
  beginVisibleReplyStream,
  idleVisibleReplyPresentationState,
  reconcileVisibleReplySnapshot,
  reduceVisibleReplyDraft,
  type VisibleReplyDraftFrame,
  type VisibleReplyPresentationState,
} from "../visibleReplyPresentation";

describe("visible reply presentation", () => {
  it("holds an exact cancelled draft until the replacement snapshot", () => {
    const streaming = applyDraft(readyPresentation(), frame({ text: "Hel" }));
    const completed = applyDraft(
      streaming,
      frame({ kind: "completed", text: "Hello" })
    );

    expect(completed.activeDraft).toMatchObject({
      status: "completed",
      text: "Hello",
    });
    const cancelled = reduceVisibleReplyDraft(
      completed,
      1,
      frame({ kind: "cancelled" })
    );
    expect(cancelled.restartStream).toBe(true);
    expect(cancelled.presentation.activeDraft).toBe(completed.activeDraft);

    const reconnecting = beginVisibleReplyStream(cancelled.presentation, 2);
    expect(reconnecting.activeDraft).toBe(completed.activeDraft);
    expect(
      reconcileVisibleReplySnapshot(reconnecting, 2, []).activeDraft
    ).toBeUndefined();
  });

  it("installs the current Participant draft in the reconnect snapshot without a blank state", () => {
    const first = applyDraft(readyPresentation(), frame({ text: "Old" }));
    const awaiting = beginVisibleReplyStream(first, 2);

    expect(
      reduceVisibleReplyDraft(
        awaiting,
        1,
        frame({ kind: "delta", text: "Old callback" })
      ).presentation
    ).toBe(awaiting);
    expect(
      reduceVisibleReplyDraft(
        awaiting,
        2,
        frame({ kind: "delta", text: "Before snapshot" })
      ).presentation
    ).toBe(awaiting);

    const ready = reconcileVisibleReplySnapshot(
      awaiting,
      2,
      [],
      frame({ text: "Old continued" })
    );
    expect(ready.activeDraft?.text).toBe("Old continued");
    expect(ready.activeDraftIncarnation).toBe(2);
    expect(reconcileVisibleReplySnapshot(ready, 1, [], null)).toBe(ready);
    expect(
      reconcileVisibleReplySnapshot(ready, 2, [], null).activeDraft
    ).toBeUndefined();
  });

  it("allows a later send in the same activation after a reliable empty owner snapshot", () => {
    const first = applyDraft(readyPresentation(), frame({ text: "First send" }));
    const empty = reconcileVisibleReplySnapshot(
      beginVisibleReplyStream(first, 2),
      2,
      [],
      null
    );
    expect(empty.activeDraft).toBeUndefined();
    const next = applyDraft(
      empty,
      frame({ draftId: "draft_next_send", revision: 1, text: "Second send" })
    );
    expect(next.activeDraft?.text).toBe("Second send");
  });

  it("keeps a current draft when an earlier reply's canonical snapshot arrives late", () => {
    const current = frame({
      responseKey: "response_B",
      sourceMessageIds: ["source_B"],
      revision: 1,
      text: "Reply B is growing",
    });
    const streaming = applyDraft(readyPresentation(), current);
    const lateReplyA = { messageId: "canonical_A", role: "assistant" } as ChatMessage;
    const installed = reconcileVisibleReplySnapshot(
      beginVisibleReplyStream(streaming, 2),
      2,
      [lateReplyA],
      current
    );
    expect(installed.activeDraft?.text).toBe("Reply B is growing");
    expect(
      applyDraft(installed, {
        ...current,
        kind: "delta",
        revision: 2,
        delta: " after A arrives",
        text: "Reply B is growing after A arrives",
      }).activeDraft?.text
    ).toBe("Reply B is growing after A arrives");
  });

  it("does not retire a live response when the independent Participant snapshot is unavailable", () => {
    const first = applyDraft(readyPresentation(), frame({ text: "Before owner loss" }));
    const unavailable = reconcileVisibleReplySnapshot(
      beginVisibleReplyStream(first, 2),
      2,
      [],
      undefined
    );
    expect(unavailable.activeDraft).toBeUndefined();
    const recovered = reconcileVisibleReplySnapshot(
      beginVisibleReplyStream(unavailable, 3),
      3,
      [],
      frame({ text: "Owner recovered" })
    );
    expect(recovered.activeDraft?.text).toBe("Owner recovered");
  });

  it("keeps the existing one-reconnect cancellation fence without ending the activation", () => {
    const first = applyDraft(readyPresentation(), frame({ text: "Cancelled" }));
    const cancelled = reduceVisibleReplyDraft(
      first,
      1,
      frame({ kind: "cancelled" })
    ).presentation;
    const second = reconcileVisibleReplySnapshot(
      beginVisibleReplyStream(cancelled, 2),
      2,
      [],
      frame({ draftId: "draft_next_send", revision: 1, text: "Second send" })
    );
    const third = reconcileVisibleReplySnapshot(
      beginVisibleReplyStream(second, 3),
      3,
      [],
      frame({ draftId: "draft_next_send", revision: 1, text: "Second send" })
    );
    // Existing boundary: the first reconnect cannot distinguish the next send
    // from a queued cancelled frame. The fence expires after that incarnation.
    expect(second.activeDraft).toBeUndefined();
    expect(third.activeDraft?.text).toBe("Second send");
  });

  it("requires the exact transient identity for deltas and cancellation", () => {
    const started = applyDraft(readyPresentation(), frame({ text: "Partial" }));
    const wrongScope = frame({
      kind: "cancelled",
      sourceMessageIds: ["msg_u2", "msg_u1"],
    });
    expect(reduceVisibleReplyDraft(started, 1, wrongScope).presentation).toBe(started);

    const cancelled = reduceVisibleReplyDraft(started, 1, frame({ kind: "cancelled" }));
    expect(cancelled.restartStream).toBe(true);
    expect(cancelled.presentation.activeDraft).toBe(started.activeDraft);
  });

  it("accepts only a started frame when another draft supersedes the active one", () => {
    const old = applyDraft(readyPresentation(), frame({ text: "Old" }));
    const unrelatedDelta = reduceVisibleReplyDraft(
      old,
      1,
      frame({
        draftId: "draft_2",
        kind: "delta",
        responseKey: "rsp_2",
        sourceMessageIds: ["msg_u3"],
        text: "New delta",
      })
    );
    expect(unrelatedDelta.presentation).toBe(old);

    const replacement = reduceVisibleReplyDraft(
      old,
      1,
      frame({
        draftId: "draft_2",
        responseKey: "rsp_2",
        sourceMessageIds: ["msg_u3"],
        text: "New",
      })
    );
    expect(replacement.presentation.activeDraft).toMatchObject({
      draftId: "draft_2",
      text: "New",
    });
  });

  it("appends continuous revision deltas and recovers safely from a gap", () => {
    const started = applyDraft(
      readyPresentation(),
      frame({ revision: 0, text: "Hel" })
    );
    const continuous = applyDraft(
      started,
      frame({ delta: "lo", kind: "delta", revision: 1, text: "xxxxx" })
    );
    expect(continuous.activeDraft).toMatchObject({ revision: 1, text: "Hello" });

    const recovered = applyDraft(
      continuous,
      frame({
        delta: "ignored-gap-delta",
        kind: "delta",
        revision: 3,
        text: "Hello world",
      })
    );
    expect(recovered.activeDraft).toMatchObject({
      revision: 3,
      text: "Hello world",
    });
  });
});

function readyPresentation(state = idleVisibleReplyPresentationState, incarnation = 1) {
  return reconcileVisibleReplySnapshot(
    beginVisibleReplyStream(state, incarnation),
    incarnation,
    []
  );
}

function applyDraft(
  state: VisibleReplyPresentationState,
  draftFrame: VisibleReplyDraftFrame
) {
  return reduceVisibleReplyDraft(state, state.incarnation, draftFrame).presentation;
}

function frame(
  overrides: Partial<VisibleReplyDraftFrame> = {}
): VisibleReplyDraftFrame {
  return {
    conversationId: "cnv_1",
    draftId: "draft_1",
    kind: "started",
    responseKey: "rsp_1",
    sourceMessageIds: ["msg_u1", "msg_u2"],
    text: "",
    ...overrides,
  };
}
