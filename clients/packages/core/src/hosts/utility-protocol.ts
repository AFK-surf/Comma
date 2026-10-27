// What Main and the core's utility process say to each other (hosts/node.ts), and the session values both sides name
// (host.ts re-exports them). No imports but the session, chat and core contracts' types: Main uses it without the core
// itself.
import type { ChatLocalFile, ChatPickAttachmentError } from "@comma/chat-contract";
import type { LocalDriveListInput, LocalDriveOp } from "../host.ts";
import type { SessionCleanup, SessionProblem } from "@comma/session-contract";
import type {
  MeetingCaptureState,
  MeetingPresenceMeeting,
  MeetingPresenceState,
  MeetingRecording,
} from "../contract.ts";

export type {
  MeetingCaptureState,
  MeetingPresenceMeeting,
  MeetingPresenceState,
  MeetingRecording,
} from "../contract.ts";

/** The operating system a sign-in names. */
export type ClientPlatform =
  | "android"
  | "ios"
  | "linux"
  | "macos"
  | "unknown"
  | "windows";

/** The kind of client a sign-in names: what its Google sign-in gives the server depends on it. */
export type ClientKind = "android" | "electron" | "ios";

/**
 * A credential the host keeps (Electron: Main's SecureStore), named by an opaque reference the host made: the core
 * never sees the credential itself. A reference means something only to the host that gave it.
 */
export type CredentialRef = string;

/** A session credential the host keeps, as the core may know it: who and which session, never the bearer. */
export interface BearerCredential {
  ref: CredentialRef;
  audience: string;
  sessionId: string;
  userId: string;
  email: string;
  expiresAtEpochSeconds: number;
}

/** What the host's credential store holds, as the core may know it. */
export type BearerVault =
  | {
      status: "readable";
      /** The credential product requests carry once the session is confirmed. */
      active: BearerCredential | null;
      /** Credentials to revoke at the server (signed out, replaced, or issued to a sign-in that lost). */
      pending: { ref: CredentialRef; audience: string; sessionId?: string }[];
      cleanup: SessionCleanup;
    }
  | { status: "indeterminate"; problem: SessionProblem };

/**
 * A change of the host's credential store, by reference. `issued` names a credential a sign-in's answer carried (the
 * host took it out of the answer); each such reference is settled by `commit`, `quarantine` or `release`.
 */
export type BearerVaultChange =
  /**
   * The issued credential becomes the active one; one active before it, and the credentials issued to the sign-ins
   * it replaced (`supersede`), are queued for revocation in the same write.
   */
  | { kind: "commit"; issued: CredentialRef; supersede: CredentialRef[] }
  /** The active credential, confirmed by the server: kept, with the identity the server answered. */
  | {
      kind: "adopt";
      active: CredentialRef;
      identity: Omit<BearerCredential, "ref" | "audience">;
    }
  /** The active credential is no session's any more (a 401): removed. */
  | { kind: "invalidate"; active: CredentialRef }
  /** Signing out: the active credential is queued for revocation. */
  | { kind: "signOut" }
  /** An issued credential a sign-in no longer wants: queued for revocation (true once it is). */
  | { kind: "quarantine"; issued: CredentialRef }
  /** An issued credential the core revoked at the server itself: the host forgets it. */
  | { kind: "release"; issued: CredentialRef }
  /** A queued credential the server no longer knows: dropped from the queue. */
  | { kind: "revoked"; pending: CredentialRef }
  /** Credentials for another audience (the configured server changed) are dropped, not sent anywhere. */
  | { kind: "retainAudience" };

/**
 * What Google's sign-in gave, and the host's handle to say how it ended (`grant`): the code the server exchanges
 * (Electron's window), or an ID token bound to the attempt's nonce (Android's account chooser).
 */
export type GoogleGrant =
  | {
      authorizationCode: string;
      codeVerifier: string;
      redirectUri: string;
      grant: string;
    }
  | { idToken: string; grant: string };

/** What the iPhone's Sign in with Apple sheet gave: the identity token bound to the attempt's nonce. */
export interface AppleGrant {
  identityToken: string;
}

/** An authority's place, kept across a core's restart (Electron: by Main's gate; the web: in device storage). */
export interface SessionAuthorityResume {
  authorityInstanceId: string;
  generation: number;
  revision: number;
  sessionId: string | null;
}

/** The session a request belongs to (no credential in it). */
export interface UtilityLease {
  audience: string;
  authorityInstanceId: string;
  generation: number;
  sessionId: string;
}

/** A release the update feed offers: its version, and the platform's own record of it (passed back as it came). */
export interface AppRelease {
  version: string;
  release: unknown;
}

/** The app's update feed as the platform answers it. */
export interface AppUpdateStatus {
  /** This build has an update feed. */
  configured: boolean;
  productName?: string | undefined;
  /** Why the feed cannot be used now. */
  error?: string | undefined;
  /** A release downloaded before, waiting for a restart. */
  pendingRestart?: AppRelease | undefined;
}

export const CORE_START = "comma-core:start";

/** A local file snapshot Main made of a saved recording, named by its opaque reference (no host path). */
export interface MeetingLocalFile {
  localFileRef: string;
  mediaType: string;
  name: string;
  size: number;
}

/** The meeting settings a person chose (Main keeps them with the client settings). */
export interface MeetingPreferences {
  meetingStartRecording: "reminder" | "auto";
  meetingHideRecorder: boolean;
  meetingSmartSummary: boolean;
}

/** What Main tells the core's meeting recorder it saw. */
export type MeetingEvent =
  /** Meeting presence: the first one tells the core detection started. */
  | { kind: "presence"; state: MeetingPresenceState }
  /** The capture's state, and the meeting Main started it for (Main keeps it across a core restart). */
  | { kind: "capture"; state: MeetingCaptureState; meetingKey?: string | undefined }
  | { kind: "preferences"; preferences: MeetingPreferences }
  /** Whether the main window shows (it shows the saved recording's receipt). */
  | { kind: "clientVisible"; visible: boolean };

/** Why Main could not do what the core asked: only what the core needs to word and retry it (no paths, no bodies). */
export type MeetingFailure =
  /** The workspace Connector did not register the file: `retryable` when it may later. */
  | {
      kind: "registration";
      retryable: boolean;
      remediation?: "reissue_connector_token" | undefined;
    }
  /** The local file store refused the snapshot. */
  | { kind: "snapshot"; errorClass: string }
  /** The disk refused (`ENOSPC`, `EACCES`, ...). */
  | { kind: "storage"; code: string }
  /** The lease named is not Main's current one. */
  | { kind: "session" }
  /** Anything else: `reason` when it may be shown. */
  | { kind: "failed"; reason?: string | undefined };

/** Each meeting command the core gives Main: its input and what Main answers. */
export interface MeetingOps {
  /** Starts capture for `meeting` (Main shows its recorder window first, unless hidden). */
  start: {
    input: {
      lease: UtilityLease;
      meeting: MeetingPresenceMeeting;
      archiveAtMs?: number;
    };
    output: MeetingCaptureState;
  };
  /** Stops and saves to Drive: the recording, and the local copy Main may snapshot later. */
  stop: {
    input: { lease: UtilityLease };
    output:
      | { status: "ready"; recording: MeetingRecording; sourcePath: string }
      | { status: "unavailable"; reason?: string | undefined };
  };
  pause: { input: null; output: MeetingCaptureState };
  resume: { input: null; output: MeetingCaptureState };
  cancel: { input: null; output: MeetingCaptureState };
  selectMicrophone: {
    input: { lease: UtilityLease; deviceId: string | null };
    output: MeetingCaptureState;
  };
  /** Asks the person whether a meeting found after a restart is the one before it. */
  recover: { input: { name: string }; output: "resume" | "new" };
  /** A local file snapshot of a saved recording (`sourcePath`, as `stop` answered it). */
  snapshot: {
    input: { lease: UtilityLease; sourcePath: string };
    output: MeetingLocalFile;
  };
  /** Registers the snapshot with the workspace's Connector. */
  register: {
    input: { lease: UtilityLease; workspaceId: string; file: MeetingLocalFile };
    output: null;
  };
  /** The server accepted the file: Main keeps it bound to its route. */
  markBound: { input: { localFileRef: string }; output: null };
  /** Writes a file into the local Drive (synchronicity): `content` base64. */
  write: {
    input: { lease: UtilityLease; space: string; path: string; content: string };
    output: null;
  };
  /** The meeting journal Main kept before the core (`meeting-tasks.json`), as text; null when there is none. */
  legacy: { input: null; output: string | null };
}

export type MeetingOp = keyof MeetingOps;

/** A meeting command (`meeting` from the core). */
export type MeetingCall = {
  [O in MeetingOp]: { op: O; input: MeetingOps[O]["input"] };
}[MeetingOp];

/** Main's answer to a meeting command: its value, or why it failed. */
export type MeetingAnswer<O extends MeetingOp = MeetingOp> =
  | { ok: MeetingOps[O]["output"] }
  | { failure: MeetingFailure };

/** What the core's session lifecycle needs of Main from the start (`BearerSessionPorts`' fixed values). */
export interface UtilitySessionStart {
  apiOrigin: string;
  clientPlatform: ClientPlatform;
  /** The app's version, as the core's requests report it (`Host.client`). */
  appVersion?: string;
  resumed: SessionAuthorityResume;
}

/**
 * What the desktop ports need from Main at the start: the app's names, and the pages a loopback listener shows (Main
 * renders them, each sign-in's received, denied, invalid and not-found page) with their Content-Security-Policy.
 */
export interface UtilityDesktopStart {
  app: { urlScheme: string; productName: string };
  pages: Record<
    "subscription" | "byok",
    Record<"received" | "denied" | "invalid" | "notFound", string>
  >;
  csp: string;
  /** Main answers the app's updates (`update*` ops). */
  updates?: true | undefined;
}

/**
 * A chat attachment pick Main makes for the core (`chatPick`): the native dialog on window `surfaceId`, within the
 * draft's quota. Main registers each local file it keeps under the core's intake `intakeId` (asking the core with
 * `chat.intake.check` before each), under the session `lease`.
 */
export interface ChatPickRequest {
  intakeId: string;
  surfaceId: string;
  workspaceId: string;
  lease: {
    audience: string;
    authorityInstanceId: string;
    generation: number;
    sessionId: string;
  };
  maxFiles: number;
  maxTotalSize: number;
  maxUploadFiles: number;
}

/** A file a pick gave: an image's bytes to upload, or a local file Main registered (its opaque ref). */
export type ChatPickedItem =
  | { kind: "upload"; name: string; size: number; bytes: Uint8Array }
  | { kind: "local_file"; file: ChatLocalFile };

/** What a pick gave: the files, and why each other selected file was refused; `cancelled` when the dialog was. */
export interface ChatPickAnswer {
  cancelled: boolean;
  errors: ChatPickAttachmentError[];
  items: ChatPickedItem[];
}

/** Whether the person is at this computer (`presence`). */
export interface UtilityPresence {
  idleSeconds: number;
  homeRepliesShown: boolean;
}

/**
 * A port the core asks Main for, by `id` (the session's, and the desktop's: presence, the system browser, the app's
 * return, a chat attachment pick, a media stream); Main answers `session-done` with its value or why it failed.
 */
export type UtilitySessionCall =
  | {
      op: "auth";
      input: {
        method: "GET" | "POST";
        path: string;
        headers: [string, string][];
        body: Uint8Array | null;
        credential?: string;
      };
    }
  | { op: "vault"; input: null }
  | { op: "change"; input: BearerVaultChange }
  | { op: "google"; input: { clientId: string; nonce: string } }
  | { op: "googleDone"; input: { grant: string; ok: boolean } }
  | { op: "presence"; input: null }
  | { op: "openExternal"; input: { url: string } }
  | { op: "returnToApp"; input: null }
  | { op: "updateStatus"; input: null }
  | { op: "updateCheck"; input: null }
  | { op: "updateDownload"; input: AppRelease }
  | { op: "updateApply"; input: AppRelease }
  | { op: "chatPick"; input: ChatPickRequest }
  | { op: "saveDownload"; input: { fileName: string; content: Uint8Array } }
  | { op: "saveOpen"; input: { fileName: string } }
  | { op: "saveWrite"; input: { id: number; bytes: Uint8Array } }
  | { op: "saveClose"; input: { id: number; keep: boolean } }
  | { op: "openStream"; input: UtilityStreamRead & { type: string } }
  | { op: "closeStream"; input: { url: string } }
  | { op: "saveStream"; input: UtilityFileRead & { fileName: string } };

/**
 * Where Main reads a file's bytes for the core: the API's GET `path` under the session `lease` names, or a signed `url`
 * that is its own authority (an attachment's, from the blob store), read with no credential.
 */
export type UtilityFileRead = { path: string; lease: UtilityLease } | { url: string };

/** Where Main reads a stream's bytes: as a file read, or from the core (`core`: a file source it reads, as JSON). */
export type UtilityStreamRead = UtilityFileRead | { core: string };

/** Each session port's answer. */
export type UtilitySessionAnswer = {
  auth: { status: number; headers: [string, string][]; body: Uint8Array };
  vault: BearerVault;
  change: BearerVault | boolean | null;
  google: GoogleGrant;
  googleDone: null;
  presence: UtilityPresence;
  openExternal: null;
  returnToApp: null;
  updateStatus: AppUpdateStatus;
  updateCheck: AppRelease | null;
  updateDownload: boolean;
  updateApply: boolean;
  chatPick: ChatPickAnswer;
  saveDownload: { downloadRef: string; fileName: string } | null;
  saveOpen: { id: number };
  saveWrite: null;
  saveClose: { downloadRef: string; fileName: string } | null;
  openStream: string;
  closeStream: null;
  saveStream: SavedStream;
};

/** What a streamed save came to: the saved file, the server's refusal, or null when it was not written. */
export type SavedStream =
  | { downloadRef: string; fileName: string }
  | { status: number; code: string }
  | null;

export type MainToCore =
  | { type: "device-setup-done"; id: number; value?: unknown; error?: string }
  | {
      type: typeof CORE_START;
      dataDir: string;
      /** Main's cache of Tasks from before the core, brought over once per account. */
      legacyTasksPath?: string | undefined;
      /** Main's meeting journal from before the core, brought over once. */
      legacyMeetingTasksPath?: string | undefined;
      /** Main's credential store and gate: the core runs the session lifecycle against them. */
      session: UtilitySessionStart;
      /** Main runs this installation's Drive node: the core reads it (`drive`). */
      localDrive?: true | undefined;
      /** The desktop ports' fixed values (absent: the core has no desktop ports). */
      desktop?: UtilityDesktopStart | undefined;
      /**
       * An Electron e2e's (never a release's): the core's clock stands still from the start, and moves only when Main
       * says (`clock`).
       */
      testClock?: true | undefined;
      /** Where the test clock starts on the wall clock (Main's test clock now): both read one time. */
      testClockStart?: number | undefined;
      /** An Electron e2e's (never a release's): where its stations are, by endpoint id (loopback addresses). */
      stationPeers?: Record<string, string[]> | undefined;
      /** The station's mesh addon (`mesh.node`) in the station the app carries: the core's endpoint to stations. */
      meshAddon?: string | undefined;
    }
  /** Moves the core's test clock `ms` forward (`testClock`); answered `clock-done` once what fell due settled. */
  | { type: "clock"; id: number; ms: number }
  /** The Drive node's answer to `drive`: its state or a listing page, or why it failed. */
  | { type: "drive-done"; id: number; value?: unknown; error?: string }
  /** The Drive node's files changed. */
  | { type: "drive-changed" }
  /** A session port's answer (`session` from the core). */
  | { type: "session-done"; id: number; value?: unknown; error?: string }
  /** Main refused a window's request for `lease` (a 401 on its `/v1` proxy): its gate is shut. */
  | { type: "rejected"; lease: UtilityLease; status: 401 | 409 }
  /**
   * A channel to the core: a window's (`surface`, its id) or Main's own (`host: true`, which may make the calls that
   * answer credentials). `session: false`: the window may not sign in or out (its `session.*` calls are refused).
   */
  | { type: "client"; surface?: string; session?: false; host?: true }
  | { type: "head"; id: number; status: number; headers: [string, string][] }
  | { type: "chunk"; id: number; bytes: Uint8Array }
  | { type: "end"; id: number }
  | { type: "fail"; id: number; message: string }
  /** Main's preview of a workspace image (`preview`), or why it could not draw one. */
  | { type: "preview-done"; id: number; bytes?: Uint8Array; error?: string }
  /** The part of a local file Main read (`local-read`), or why it could not. */
  | { type: "local-read-done"; id: number; bytes?: Uint8Array; error?: string }
  /** Main's answer to a meeting command (`meeting`), or why it could not answer (`error`). */
  | { type: "meeting-done"; id: number; answer?: MeetingAnswer; error?: string }
  /** What Main's meeting recorder parts saw (presence, capture, the settings, the main window). */
  | { type: "meeting-event"; event: MeetingEvent }
  /** What the voice call's socket did (`voice-call`). */
  | { type: "voice-call-event"; event: VoiceCallSocketEvent };

/**
 * The voice call socket Main holds for the core (`VoiceCallPorts`): it opened, a `comma.voice.v1` text message came,
 * or it closed with a WebSocket close code (0 when it never opened) and reason.
 */
export type VoiceCallSocketEvent =
  | { kind: "open" }
  | { kind: "message"; text: string }
  | { kind: "closed"; code: number; reason: string };

/** What the core asks of the voice call socket: open one with a voice key, send a text message, or close it. */
export type VoiceCallSocketOp =
  | { op: "open"; url: string; key: string }
  | { op: "send"; text: string }
  | { op: "close" };

export type CoreToMain =
  | {
      type: "device-setup";
      id: number;
      op: Parameters<import("../host.ts").DeviceSetupPort["call"]>[0];
      input: Record<string, unknown>;
    }
  | {
      type: "fetch";
      id: number;
      method: string;
      path: string;
      headers: [string, string][];
      body: Uint8Array | null;
      /** The body is this local file's bytes, which Main reads as it sends (an upload); `body` is then null. */
      localFileRef?: string;
      lease: UtilityLease;
    }
  | { type: "abort"; id: number }
  /** A session port (`UtilitySessionCall`); `abort` with its id gives it up (an auth request, the Google window). */
  | ({ type: "session"; id: number } & UtilitySessionCall)
  /** An answer to `id` came after the core gave the request up: what it carried, Main queues for revocation. */
  | { type: "session-dropped"; id: number }
  /** The snapshot the core publishes and the lease it gives: Main's gate moves on it, in the order told. */
  | { type: "gate"; snapshot: unknown; lease: UtilityLease | null }
  /**
   * The core's test clock moved as `clock` asked, and what fell due settled; or why it could not move. `now` is its
   * time after the move and `nextDue` when its earliest timer falls due, both on the wall clock.
   */
  | { type: "clock-done"; id: number; error?: string; now?: number; nextDue?: number }
  /** A workspace image the core read, for Main to draw again with the platform's decoder. */
  | { type: "preview"; id: number; bytes: Uint8Array; mediaType: string }
  /**
   * `length` bytes from `offset` of a local file a pick left with Main (`Host.readLocalFile`): a part of it going up to
   * a station. Answered `local-read-done`, with fewer bytes only where the file ends.
   */
  | {
      type: "local-read";
      id: number;
      localFileRef: string;
      offset: number;
      length: number;
    }
  /** A request to the Drive node: its state, one page of a space's listing, or one of its operations (`run`). */
  | { type: "drive"; id: number; op: "state" }
  | { type: "drive"; id: number; op: "list"; input: LocalDriveListInput }
  | { type: "drive"; id: number; op: "run"; name: LocalDriveOp; input: unknown }
  /** A meeting command for Main (`MeetingOps`): answered `meeting-done`. */
  | ({ type: "meeting"; id: number } & MeetingCall)
  /** The voice call socket (`VoiceCallSocketOp`); what it does comes back as `voice-call-event`. */
  | ({ type: "voice-call" } & VoiceCallSocketOp)
  /**
   * The core cleared what it keeps (`app.reset`): Main resets the app and starts a new core; this process ends with
   * it, unanswered.
   */
  | { type: "reset" };
