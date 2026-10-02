// Salix owns the permit. This record only enforces it at the Container carrier.
// It is not a workload lifecycle or a second Gateway attempt ledger.
export type ControlPermit = {
  owner_id: string;
  operation_id: string;
  generation: number;
  revision: number;
  claim_id: string;
};

export type ControlAction = "ensure" | "import" | "export" | "connect" | "connector_control" | "keepalive" | "destroy";
export type PendingCommand = ControlPermit & {
  action: ControlAction;
  archive_operation?: string;
  start_issued?: true;
};
export type TerminalCommand = PendingCommand & { outcome: "completed" | "not_issued"; status?: number };
export type ControlState = Omit<ControlPermit, "claim_id"> & {
  sealed: boolean;
  pending: PendingCommand | null;
  last_terminal: TerminalCommand | null;
};

export class ControlError extends Error {
  constructor(readonly code: string, readonly status = 409) {
    super(code);
  }
}

export function parseControlPermit(value: unknown): ControlPermit {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new ControlError("control_permit_required");
  }
  const p = value as Record<string, unknown>;
  for (const key of ["owner_id", "operation_id", "claim_id"] as const) {
    if (typeof p[key] !== "string" || p[key].length < 1 || p[key].length > 128 || /[\x00-\x1f\x7f]/.test(p[key])) {
      throw new ControlError("invalid_control_permit", 400);
    }
  }
  for (const key of ["generation", "revision"] as const) {
    if (!Number.isSafeInteger(p[key]) || Number(p[key]) < 1) {
      throw new ControlError("invalid_control_permit", 400);
    }
  }
  return {
    owner_id: p.owner_id as string,
    operation_id: p.operation_id as string,
    generation: p.generation as number,
    revision: p.revision as number,
    claim_id: p.claim_id as string,
  };
}

export function requestControlPermit(request: Request): ControlPermit {
  const raw = new URL(request.url).searchParams.get("salix_control");
  if (!raw || raw.length > 2048) throw new ControlError("control_permit_required");
  let value: unknown;
  try { value = JSON.parse(raw); } catch { throw new ControlError("invalid_control_permit", 400); }
  return parseControlPermit(value);
}

export type ControlStorage = {
  read(): ControlState | undefined;
  write(state: ControlState): void;
  sync(): Promise<void>;
};

// One current command, serialized only through its HTTP response / WS handshake.
// A failed transport or DO restart leaves this command unresolved. Neither an
// empty in-memory promise set nor elapsed time clears the durable pending value.
export class ContainerControl {
  constructor(private readonly storage: ControlStorage) {}

  observe(): ControlState | undefined { return this.storage.read(); }

  async open(permit: ControlPermit): Promise<ControlState> {
    const p = parseControlPermit(permit);
    const state = this.storage.read();
    if (state) {
      this.assertOwner(state, p);
      if (this.matches(state, p) && !state.sealed) return state;
      if (state.pending) throw new ControlError("control_command_unsettled");
      if (!state.sealed) throw new ControlError("control_seal_required");
      if (p.revision <= state.revision) throw new ControlError("stale_control_permit");
    }
    const next: ControlState = {
      owner_id: p.owner_id, operation_id: p.operation_id,
      generation: p.generation, revision: p.revision,
      sealed: false, pending: null, last_terminal: state?.last_terminal ?? null,
    };
    this.storage.write(next);
    await this.storage.sync();
    return this.current(p, false);
  }

  async seal(permit: ControlPermit): Promise<ControlState> {
    const p = parseControlPermit(permit);
    const state = this.storage.read();
    if (!state) throw new ControlError("control_owner_unbound");
    this.assertOwner(state, p);
    if (p.revision < state.revision || (p.revision === state.revision && !this.matches(state, p))) {
      throw new ControlError("stale_control_permit");
    }
    const next: ControlState = {
      ...state, operation_id: p.operation_id, generation: p.generation,
      revision: p.revision, sealed: true,
    };
    this.storage.write(next);
    await this.storage.sync();
    return this.current(p, true);
  }

  // Call immediately before a native side effect, with no intervening await.
  // Reading durable storage also rejects an obsolete DO instance after eviction.
  current(permit: ControlPermit, sealed?: boolean): ControlState {
    const p = parseControlPermit(permit);
    const state = this.storage.read();
    if (!state) throw new ControlError("control_owner_unbound");
    this.assertOwner(state, p);
    if (!this.matches(state, p)) throw new ControlError("stale_control_permit");
    if (sealed !== undefined && state.sealed !== sealed) {
      throw new ControlError(sealed ? "control_seal_required" : "control_sealed");
    }
    return state;
  }

  async run<T>(
    permit: ControlPermit,
    action: ControlAction,
    invoke: () => Promise<T>,
    terminal: (value: T) => { status?: number },
    options: { sealed?: boolean; archive_operation?: string } = {},
  ): Promise<T> {
    const p = parseControlPermit(permit);
    const state = this.current(p, options.sealed ?? false);
    if (state.pending) throw new ControlError("control_command_unsettled");
    // Retries of a completed request use its existing receipt / owner observation;
    // replaying a destroy after a new incarnation must never become a new call.
    if (state.last_terminal?.claim_id === p.claim_id) {
      throw new ControlError("control_command_completed");
    }
    const pending: PendingCommand = { ...p, action, ...options.archive_operation && { archive_operation: options.archive_operation } };
    this.storage.write({ ...state, pending });
    await this.storage.sync();
    try {
      const admitted = this.current(p, options.sealed ?? false);
      if (admitted.pending?.claim_id !== p.claim_id) throw new ControlError("control_command_changed");
    } catch (error) {
      // This invocation has not called the carrier. A seal that won the storage
      // flush race can record that exact fact; transport failures cannot.
      const latest = this.storage.read();
      if (latest?.sealed && latest.pending?.claim_id === p.claim_id) {
        this.storage.write({ ...latest, pending: null, last_terminal: { ...pending, outcome: "not_issued" } });
        await this.storage.sync();
      }
      throw error;
    }
    // invoke starts synchronously. It must not hide a delayed auto-start retry.
    const result = await invoke();
    const evidence = terminal(result);
    const latest = this.storage.read();
    if (latest?.last_terminal?.claim_id === p.claim_id && latest.last_terminal.outcome === "completed") return result;
    if (!latest || latest.pending?.claim_id !== p.claim_id) throw new ControlError("control_command_changed");
    this.storage.write({ ...latest, pending: null, last_terminal: { ...pending, outcome: "completed", ...evidence } });
    await this.storage.sync();
    return result;
  }

  startIssued(permit: ControlPermit): void {
    const state = this.current(permit, false);
    if (state.pending?.claim_id !== permit.claim_id || state.pending.action !== "ensure") throw new ControlError("control_command_changed");
    this.storage.write({ ...state, pending: { ...state.pending, start_issued: true } });
  }

  async confirmReady(permit: ControlPermit): Promise<void> {
    const state = this.current(permit);
    const pending = state.pending;
    if (pending?.action !== "ensure" || !pending.start_issued ||
        pending.owner_id !== permit.owner_id || pending.generation !== permit.generation) return;
    // There is no SDK start retry behind the one issued native start. A ready
    // response from this exact Container therefore settles that start request.
    this.storage.write({ ...state, pending: null, last_terminal: { ...pending, outcome: "completed", status: 200 } });
    await this.storage.sync();
  }

  async confirmImported(permit: ControlPermit, operation: string): Promise<void> {
    const state = this.current(permit);
    const pending = state.pending;
    if (pending?.action !== "import" || pending.archive_operation !== operation ||
        pending.owner_id !== permit.owner_id || pending.generation !== permit.generation) return;
    // Connector status uses the import mutex and checks the immutable import
    // operation. Once restored, late part/finish calls return that same receipt.
    this.storage.write({ ...state, pending: null, last_terminal: { ...pending, outcome: "completed", status: 200 } });
    await this.storage.sync();
  }

  async confirmStartEnded(issued: ControlPermit): Promise<void> {
    const state = this.storage.read();
    const pending = state?.pending;
    if (!state || pending?.action !== "ensure" || !pending.start_issued ||
        (["owner_id", "operation_id", "generation", "revision", "claim_id"] as const)
          .some((key) => pending[key] !== issued[key])) return;
    this.storage.write({ ...state, pending: null,
      last_terminal: { ...pending, outcome: "completed", status: 503 } });
    await this.storage.sync();
  }

  private assertOwner(state: ControlState, p: ControlPermit): void {
    if (state.owner_id !== p.owner_id || p.generation < state.generation) throw new ControlError("stale_control_owner");
  }

  private matches(state: ControlState, p: ControlPermit): boolean {
    return state.owner_id === p.owner_id && state.operation_id === p.operation_id &&
      state.generation === p.generation && state.revision === p.revision;
  }
}
