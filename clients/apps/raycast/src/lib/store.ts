// What the extension keeps between runs. Raycast's LocalStorage is its encrypted store, shared by the commands.
import type { Environment } from "./config";

export interface KeyValueStore {
  get(key: string): Promise<string | undefined>;
  set(key: string, value: string): Promise<void>;
  remove(key: string): Promise<void>;
}

/** The extension's own Comma session. It is never the desktop app's. */
export interface Session {
  token: string;
  email: string;
  /** Epoch seconds. */
  expiresAt: number;
}

/** A connection this extension started and has not finished: only its verifier can finish it. */
export interface PendingConnect {
  verifier: string;
  /** Epoch milliseconds. */
  startedAt: number;
}

export interface Workspace {
  id: string;
  groupId: string;
  name: string;
}

/** A Workspace's Home conversation, kept so that a message needs no request to find it. */
export interface Home {
  groupId: string;
  conversationId: string;
}

export class CommaStore {
  readonly #store: KeyValueStore;
  readonly #environment: Environment;

  constructor(store: KeyValueStore, environment: Environment) {
    this.#store = store;
    this.#environment = environment;
  }

  session = () => this.#read<Session>("session");
  setSession = (session: Session) => this.#write("session", session);
  /** Signing out forgets the Workspace and its Home too: the next account may not have them. */
  async clearSession(): Promise<void> {
    await this.#store.remove(this.#key("session"));
    await this.#store.remove(this.#key("workspace"));
    await this.#store.remove(this.#key("home"));
  }

  pending = () => this.#read<PendingConnect>("pending");
  setPending = (pending: PendingConnect) => this.#write("pending", pending);
  clearPending = () => this.#store.remove(this.#key("pending"));

  workspace = () => this.#read<Workspace>("workspace");
  setWorkspace = (workspace: Workspace) => this.#write("workspace", workspace);
  clearWorkspace = () => this.#store.remove(this.#key("workspace"));

  /** The Home conversation kept for `groupId`. One kept for another Workspace does not count. */
  async home(groupId: string): Promise<string | undefined> {
    const home = await this.#read<Home>("home");
    return home?.groupId === groupId ? home.conversationId : undefined;
  }
  setHome = (home: Home) => this.#write("home", home);
  clearHome = () => this.#store.remove(this.#key("home"));

  #key(name: string): string {
    return `${this.#environment}:${name}`;
  }

  async #read<T>(name: string): Promise<T | undefined> {
    const value = await this.#store.get(this.#key(name));
    if (!value) return undefined;
    try {
      return JSON.parse(value) as T;
    } catch {
      return undefined;
    }
  }

  #write(name: string, value: unknown): Promise<void> {
    return this.#store.set(this.#key(name), JSON.stringify(value));
  }
}
