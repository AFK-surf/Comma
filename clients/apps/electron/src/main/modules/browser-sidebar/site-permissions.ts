import type { SitePermissionMenuProvider } from "../../site-permission-menu-window";
import type { Session } from "electron";
import { mkdirSync, readFileSync, renameSync, statSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import { z } from "zod";

export type SiteMediaPermission = "microphone" | "camera";
export type SitePermissionChoice = "ask" | "allow" | "block";
export type SitePermissionChoices = Record<SiteMediaPermission, SitePermissionChoice>;
const defaults = (): SitePermissionChoices => ({ microphone: "ask", camera: "ask" });
const choice = z.enum(["ask", "allow", "block"]);
const storedSites = z
  .array(
    z
      .object({
        origin: z.string().max(2048),
        microphone: choice,
        camera: choice,
      })
      .strict()
  )
  .max(256);

export interface SitePermissionContents {
  readonly id: number;
  getURL(): string;
  isDestroyed(): boolean;
  reload(): void;
  on(event: "destroyed", listener: () => void): unknown;
  on(event: "did-start-navigation", listener: (...args: unknown[]) => void): unknown;
}
export interface SitePermissionPlatform {
  menu?: SitePermissionMenuProvider;
  prepare?(owner: unknown): void;
  prompt(input: {
    owner: unknown;
    origin: string;
    media: SiteMediaPermission[];
    signal: AbortSignal;
  }): Promise<SitePermissionChoice>;
  settings(input: {
    anchor?: { x: number; y: number; width: number; height: number } | undefined;
    owner: unknown;
    origin: string;
    choices: SitePermissionChoices;
    signal: AbortSignal;
    change(media: SiteMediaPermission, value: SitePermissionChoice): void;
    reset(): void;
    reload(): void;
  }): Promise<void>;
  hasSystemAccess(media: SiteMediaPermission): boolean;
  ensureSystemAccess(owner: unknown, media: SiteMediaPermission[]): Promise<boolean>;
  reportError(owner: unknown, message: string): void;
}
interface Tab {
  contents: SitePermissionContents;
  owner: unknown;
  current(): boolean;
  document: AbortController;
}

export function sitePermissionOrigin(url: string): string | undefined {
  try {
    const parsed = new URL(url);
    if (parsed.protocol !== "https:" || parsed.username || parsed.password) return;
    return parsed.origin;
  } catch {
    return;
  }
}

/** Main owns decisions; web pages cannot supply the origin displayed to the user. */
export class BrowserSitePermissions {
  readonly #tabs = new Map<number, Tab>();
  readonly #sessions = new WeakSet<object>();
  readonly #sites = new Map<string, SitePermissionChoices>();
  readonly #pending = new Set<number>();
  #promptTail: Promise<unknown> = Promise.resolve();
  #storageError: string | undefined;
  #settingsOpen = false;
  #decisionVersion = 0;
  constructor(
    private readonly platform: SitePermissionPlatform,
    private readonly filePath?: string
  ) {
    if (!filePath) return;
    try {
      if (statSync(filePath).size > 1024 * 1024)
        throw new Error("Permission file is too large.");
      const entries = storedSites.parse(JSON.parse(readFileSync(filePath, "utf8")));
      for (const { origin, ...choices } of entries) {
        if (sitePermissionOrigin(origin) !== origin)
          throw new Error("Invalid website origin.");
        this.#sites.set(origin, choices);
      }
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") {
        this.#sites.clear();
        this.#storageError =
          "Website permissions could not be read. Repair or remove browser-site-permissions.json in the Comma profile, then restart Comma.";
      }
    }
  }
  choices(origin: string): SitePermissionChoices {
    return { ...(this.#sites.get(origin) ?? defaults()) };
  }
  register(contents: SitePermissionContents, owner: unknown, current: () => boolean) {
    this.platform.prepare?.(owner);
    const tab: Tab = { contents, owner, current, document: new AbortController() };
    this.#tabs.set(contents.id, tab);
    contents.on("did-start-navigation", (...args) => {
      if (args[3] === false) return;
      tab.document.abort();
      tab.document = new AbortController();
    });
    contents.on("destroyed", () => {
      tab.document.abort();
      this.#tabs.delete(contents.id);
    });
  }
  install(
    session: Pick<Session, "setPermissionCheckHandler" | "setPermissionRequestHandler">
  ) {
    if (this.#sessions.has(session)) return;
    this.#sessions.add(session);
    session.setPermissionCheckHandler((contents, permission, origin, details) => {
      const tab = contents && this.#tabs.get(contents.id);
      if (!tab || permission !== "media" || !details.isMainFrame || this.#storageError)
        return false;
      if (
        tab.contents !== contents ||
        !this.#valid(tab) ||
        sitePermissionOrigin(origin) !== sitePermissionOrigin(tab.contents.getURL())
      )
        return false;
      const media =
        details.mediaType === "audio"
          ? "microphone"
          : details.mediaType === "video"
            ? "camera"
            : undefined;
      return (
        !!media &&
        this.choices(sitePermissionOrigin(origin)!)[media] === "allow" &&
        this.platform.hasSystemAccess(media)
      );
    });
    session.setPermissionRequestHandler((contents, permission, callback, details) => {
      const tab = this.#tabs.get(contents.id);
      const origin = sitePermissionOrigin(details.requestingUrl);
      const types = "mediaTypes" in details ? details.mediaTypes : undefined;
      if (
        !tab ||
        tab.contents !== contents ||
        permission !== "media" ||
        !details.isMainFrame ||
        !origin ||
        origin !== sitePermissionOrigin(contents.getURL()) ||
        !types?.length ||
        types.some((type) => type !== "audio" && type !== "video") ||
        !this.#valid(tab) ||
        this.#pending.has(contents.id) ||
        this.#pending.size >= 32
      ) {
        callback(false);
        return;
      }
      const media = [
        ...new Set(
          types.map((type) =>
            type === "audio" ? ("microphone" as const) : ("camera" as const)
          )
        ),
      ];
      const signal = tab.document.signal;
      this.#pending.add(contents.id);
      // One outstanding request per tab, at most 32 total, one native prompt at a time.
      const request = this.#promptTail.then(() =>
        this.#request(tab, origin, media, signal)
      );
      this.#promptTail = request.catch(() => undefined);
      let answered = false;
      const answer = (allowed: boolean) => {
        if (answered) return;
        answered = true;
        signal.removeEventListener("abort", cancel);
        callback(allowed);
      };
      const cancel = () => answer(false);
      signal.addEventListener("abort", cancel, { once: true });
      void request.then(
        (allowed) => {
          this.#pending.delete(contents.id);
          answer(allowed);
        },
        (error: unknown) => {
          this.#pending.delete(contents.id);
          answer(false);
          this.platform.reportError(
            tab.owner,
            error instanceof Error ? error.message : "Website permission failed."
          );
        }
      );
    });
  }
  async showSettings(
    contents: SitePermissionContents,
    anchor?: { x: number; y: number; width: number; height: number }
  ) {
    const tab = this.#tabs.get(contents.id);
    const origin = sitePermissionOrigin(contents.getURL());
    if (!tab || !origin || !this.#valid(tab))
      return {
        status: "unavailable" as const,
        reason: "Website permissions require an active HTTPS page.",
      };
    if (this.#storageError) throw new Error(this.#storageError);
    const signal = tab.document.signal;
    const current = () =>
      !signal.aborted &&
      this.#valid(tab) &&
      sitePermissionOrigin(contents.getURL()) === origin;
    const save = (values: SitePermissionChoices) => {
      if (!current()) return;
      this.#save(origin, values);
    };
    if (this.#settingsOpen) return { status: "opened" as const };
    this.#settingsOpen = true;
    try {
      await this.platform.settings({
        anchor,
        owner: tab.owner,
        origin,
        choices: this.choices(origin),
        signal,
        change: (media, value) => save({ ...this.choices(origin), [media]: value }),
        reset: () => save(defaults()),
        reload: () => {
          if (current()) contents.reload();
        },
      });
      return { status: "opened" as const };
    } finally {
      this.#settingsOpen = false;
    }
  }
  #valid(tab: Tab) {
    return !tab.contents.isDestroyed() && tab.current();
  }
  async #request(
    tab: Tab,
    origin: string,
    media: SiteMediaPermission[],
    signal: AbortSignal
  ) {
    const current = () =>
      !signal.aborted &&
      this.#valid(tab) &&
      sitePermissionOrigin(tab.contents.getURL()) === origin;
    if (!current()) return false;
    if (this.#storageError) throw new Error(this.#storageError);
    const choices = this.choices(origin);
    if (media.some((type) => choices[type] === "block")) return false;
    const requested = media.filter((type) => choices[type] === "ask");
    if (requested.length) {
      const version = this.#decisionVersion;
      const decision = await this.platform.prompt({
        owner: tab.owner,
        origin,
        media: requested,
        signal,
      });
      if (!current() || decision === "ask" || version !== this.#decisionVersion)
        return false;
      // The decision version above also rejects reset-to-Ask while a prompt is open.
      for (const type of requested) choices[type] = decision;
      this.#save(origin, choices);
      if (decision !== "allow") return false;
    }
    const allowed = await this.platform.ensureSystemAccess(tab.owner, media);
    return (
      allowed &&
      current() &&
      media.every((type) => this.choices(origin)[type] === "allow")
    );
  }
  #save(origin: string, choices: SitePermissionChoices) {
    const next = new Map(this.#sites);
    if (choices.microphone === "ask" && choices.camera === "ask") next.delete(origin);
    else next.set(origin, choices);
    if (next.size > 256)
      throw new Error(
        "Website permission storage is full. Reset an unused site's permissions first."
      );
    if (this.filePath) {
      mkdirSync(dirname(this.filePath), { recursive: true });
      const temp = `${this.filePath}.tmp`;
      writeFileSync(
        temp,
        JSON.stringify(
          [...next].map(([siteOrigin, value]) => ({ origin: siteOrigin, ...value }))
        ),
        { mode: 0o600 }
      );
      renameSync(temp, this.filePath);
    }
    this.#decisionVersion += 1;
    this.#sites.clear();
    for (const [siteOrigin, value] of next) this.#sites.set(siteOrigin, value);
  }
}
