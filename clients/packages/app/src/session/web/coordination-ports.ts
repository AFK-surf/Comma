export type WebSessionCoordinationHint = {
  canonicalApiOrigin: string;
  cookieAuthorityId: string;
  cookieGeneration: number;
  coordinationRevision: number;
  kind: "session_maybe_changed";
  schemaVersion: 1;
  senderId: string;
};

export interface WebSessionCoordinationStorage {
  read(key: string): string | null;
  write(key: string, value: string): void;
}

export interface WebSessionExclusiveLocks {
  request<T>(name: string, signal: AbortSignal, work: () => Promise<T>): Promise<T>;
}

export interface WebSessionBroadcastChannel {
  close(): void;
  publish(hint: WebSessionCoordinationHint): void;
  subscribe(listener: (hint: unknown) => void): () => void;
}

export interface WebSessionHostPorts {
  broadcast: {
    open(name: string): WebSessionBroadcastChannel;
  };
  documentOrigin: string;
  fetch: typeof fetch;
  locks: WebSessionExclusiveLocks | undefined;
  now(): number;
  randomId(): string;
  schedule(callback: () => void, delayMs: number): number;
  storage: WebSessionCoordinationStorage;
  unschedule(handle: number): void;
}
