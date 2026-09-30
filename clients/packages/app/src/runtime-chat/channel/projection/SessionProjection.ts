import {
  chatRuntimeSessionSchema,
  chatRuntimeSnapshotSchema,
  type ChatRuntimeSnapshot,
} from "@comma/chat-contract";
import { chatRuntimeStateEnvelopeSchema } from "@comma/native-bridge";
import type { SessionProductLease } from "@comma/session-contract";
import type { DraftAttachments } from "../attachments/DraftAttachments";
import { sameSessionProductLease, type ChannelLease } from "../ChannelLease";
import { idleChannelState, type ChannelStore } from "../channelStore";
import type { ChannelDraft } from "../draft/ChannelDraft";
import type { LocalFilePreviews } from "../preview/LocalFilePreviews";
import type { ProjectionFence } from "./ProjectionFence";
import {
  overlaySeededTranscript,
  projectionToChannelState,
} from "./projectionToChannelState";
import { reconcileChannelState } from "./reconcileChannelState";

/**
 * A `chat.state` publish carries every retained session's projection, and a
 * draft keystroke in any of them republishes all of it. This channel only ever
 * reads its own session, so the envelope is checked to its header — the lease,
 * the snapshot revision and each session's key — and the projection is parsed
 * for this one session alone. A sibling session is never read, so one that
 * would fail the wire contract cannot hold this channel's own update back.
 */
const chatRuntimeStateEnvelopeHeaderSchema = chatRuntimeStateEnvelopeSchema.extend({
  snapshot: chatRuntimeSnapshotSchema.extend({
    sessions: chatRuntimeSessionSchema.pick({ key: true }).array(),
  }),
});
const chatRuntimeSessionRevisionSchema = chatRuntimeSessionSchema.shape.revision;

/** What adopting a session projection updates. */
type ProjectionTargets = {
  attachments: DraftAttachments;
  draft: ChannelDraft;
  fence: ProjectionFence;
  lease: ChannelLease;
  previews: LocalFilePreviews;
  store: ChannelStore;
};

/** The session a channel follows, and the subscriber whose view it reads. */
export type ChannelSession = {
  key: string;
  session: SessionProductLease;
  subscriberId: string;
};

/** Adopts Main's projections of this channel's session, newest first wins. */
export class SessionProjection {
  readonly #session: ChannelSession;
  readonly #targets: ProjectionTargets;
  #lastSessionRevision = -1;
  #lastSnapshotRevision = -1;
  #seeded: boolean;

  constructor(targets: ProjectionTargets, session: ChannelSession, seeded: boolean) {
    this.#targets = targets;
    this.#session = session;
    this.#seeded = seeded;
  }

  /** A new lifecycle accepts every revision again. */
  restart() {
    this.#lastSessionRevision = -1;
    this.#lastSnapshotRevision = -1;
  }

  applyEnvelope(value: unknown) {
    const header = chatRuntimeStateEnvelopeHeaderSchema.safeParse(value);
    if (
      !header.success ||
      !sameSessionProductLease(header.data.session, this.#session.session)
    ) {
      return;
    }
    const { snapshot } = header.data;
    const key = this.#session.key;
    const index = snapshot.sessions.findIndex((session) => session.key === key);
    if (index === -1) {
      this.#applySnapshot({ ...snapshot, sessions: [] });
      return;
    }
    const raw = (value as { snapshot: { sessions: { revision?: unknown }[] } }).snapshot
      .sessions[index]!;
    const revision = chatRuntimeSessionRevisionSchema.safeParse(raw.revision);
    if (!revision.success) {
      return;
    }
    // A newer snapshot whose own session revision has not moved is another
    // session's change echoing through: nothing here can differ, so neither
    // the parse nor the reconcile runs. Only the snapshot ordering advances.
    if (
      this.#targets.lease.active &&
      this.#targets.fence.hasSeenSession &&
      snapshot.revision >= this.#lastSnapshotRevision &&
      revision.data === this.#lastSessionRevision
    ) {
      this.#lastSnapshotRevision = snapshot.revision;
      return;
    }
    const session = chatRuntimeSessionSchema.safeParse(raw);
    if (!session.success) {
      return;
    }
    this.#applySnapshot({ ...snapshot, sessions: [session.data] });
  }

  #applySnapshot(snapshot: ChatRuntimeSnapshot) {
    const { attachments, draft, fence, lease, previews, store } = this.#targets;
    if (!lease.active || snapshot.revision < this.#lastSnapshotRevision) {
      return;
    }
    const isNewerSnapshot = snapshot.revision > this.#lastSnapshotRevision;
    this.#lastSnapshotRevision = snapshot.revision;
    const key = this.#session.key;
    const session = snapshot.sessions.find((candidate) => candidate.key === key);
    if (!session) {
      if (fence.hasSeenSession && isNewerSnapshot) {
        this.#clearMissingSessionProjection();
      }
      return;
    }
    if (session.revision < this.#lastSessionRevision) {
      return;
    }
    previews.ensure();
    fence.see();
    this.#lastSessionRevision = session.revision;
    const projection =
      session.surfaceProjections?.find(
        (candidate) => candidate.subscriberId === this.#session.subscriberId
      )?.state ?? session.state;
    attachments.observeIntakeInFlight(projection.attachmentIntakeInFlight === true);
    let nextState = projectionToChannelState(projection);
    if (this.#seeded) {
      // A freshly built Main entry publishes idle/loading projections before
      // its first canonical fetch settles; those must not blank the seeded
      // transcript or its conversation metadata. The seed yields exactly when
      // the entry reports "ready", adopting canonical data wholesale
      // (including a legitimately empty conversation). A settled "error"
      // keeps the transcript and metadata visible beneath the honest error
      // surface, and the error stays presented through retry publishes until
      // canonical data arrives. Pending rows from a send issued in the
      // interim overlay the seeded transcript; the overlay is always rebuilt
      // from the seed plus the projection's CURRENT pending rows, so a
      // discarded send cannot leave a ghost bubble behind
      // (reconcileChannelState restores row identities either way).
      if (nextState.status === "ready") {
        this.#seeded = false;
      } else {
        nextState = overlaySeededTranscript(nextState, store.state);
      }
    }
    const adoptedDraft = draft.adopt(nextState.draft, session.draftEpoch);
    nextState = { ...nextState, draft: adoptedDraft ?? store.state.draft };
    attachments.adopt(nextState.draftAttachments);
    // Snapshot projection re-materializes every object (IPC structured clone +
    // schema parse), but most publishes — draft keystroke echoes, unrelated
    // sessions changing, poll refreshes — carry value-identical conversation
    // data. Reconciling against the previous state preserves object identity
    // for unchanged messages (and skips the emit entirely when nothing
    // changed), which is what keeps the memoized transcript rows and compiled
    // inline elements from re-rendering the whole thread per keystroke.
    const reconciled = reconcileChannelState(store.state, {
      ...nextState,
      draftAttachments: attachments.forState(),
    });
    if (reconciled === store.state) {
      return;
    }
    store.state = reconciled;
    store.emit();
  }

  #clearMissingSessionProjection() {
    const { attachments, draft, fence, previews, store } = this.#targets;
    previews.dispose();
    attachments.clear();
    fence.end();
    draft.reset();
    this.#lastSessionRevision = -1;
    this.#seeded = false;
    store.state = idleChannelState;
    store.emit();
  }
}
