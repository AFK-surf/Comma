import {
  browserCookieImportInputSchema,
  browserImportProfileRefSchema,
  type BrowserCookieImportInput,
  type BrowserCookieImportResult,
  type BrowserImportProfile,
  type BrowserImportProfileRef,
  type BrowserImportSource,
} from "@comma/native-bridge";
import { createDecipheriv, createHash, pbkdf2Sync } from "node:crypto";
import { mkdtemp, open, readFile, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { getDomain } from "tldts";

/**
 * A Chromium browser keeps its profiles under one data folder and encrypts
 * cookie values with a key that macOS stores as the "<name> Safe Storage"
 * keychain item. Only the owning browser may read that item without asking,
 * so macOS shows the user a keychain prompt for Comma.
 */
interface ChromiumBrowser {
  appName: string;
  /** The app bundle in /Applications, for its icon. */
  bundleName: string;
  /** Relative to `~/Library/Application Support`. */
  directory: string;
  keychainAccount: string;
  keychainService: string;
}

export const chromiumBrowsers: Record<BrowserImportSource, ChromiumBrowser> = {
  chrome: {
    appName: "Google Chrome",
    bundleName: "Google Chrome.app",
    directory: "Google/Chrome",
    keychainAccount: "Chrome",
    keychainService: "Chrome Safe Storage",
  },
  arc: {
    appName: "Arc",
    bundleName: "Arc.app",
    directory: "Arc/User Data",
    keychainAccount: "Arc",
    keychainService: "Arc Safe Storage",
  },
  brave: {
    appName: "Brave",
    bundleName: "Brave Browser.app",
    directory: "BraveSoftware/Brave-Browser",
    keychainAccount: "Brave",
    keychainService: "Brave Safe Storage",
  },
  edge: {
    appName: "Microsoft Edge",
    bundleName: "Microsoft Edge.app",
    directory: "Microsoft Edge",
    keychainAccount: "Microsoft Edge",
    keychainService: "Microsoft Edge Safe Storage",
  },
  dia: {
    appName: "Dia",
    bundleName: "Dia.app",
    directory: "Dia/User Data",
    keychainAccount: "Dia",
    keychainService: "Dia Safe Storage",
  },
  comet: {
    appName: "Comet",
    bundleName: "Comet.app",
    directory: "Comet",
    keychainAccount: "Comet",
    keychainService: "Comet Safe Storage",
  },
};

export type KeychainPasswordRead =
  | { status: "found"; password: string }
  | { status: "denied" | "missing" | "failed" };

export interface ImportedCookie {
  url: string;
  name: string;
  value: string;
  domain?: string;
  path: string;
  secure: boolean;
  httpOnly: boolean;
  sameSite: "unspecified" | "no_restriction" | "lax" | "strict";
  expirationDate?: number;
}

export interface BrowserImportPlatform {
  /** `~/Library/Application Support`. */
  applicationSupportDirectory: string;
  /** The icon of an installed app bundle as a PNG data URL. */
  appIcon?: ((bundleName: string) => Promise<string | undefined>) | undefined;
  /** A private folder for the short-lived copy of a cookie database. */
  temporaryDirectory: string;
  readKeychainPassword(service: string, account: string): Promise<KeychainPasswordRead>;
  cookies: {
    /** Name, domain, path, host-only flag and value of every cookie already stored. */
    list(): Promise<
      Array<{
        domain: string;
        hostOnly: boolean;
        name: string;
        path: string;
        value: string;
      }>
    >;
    set(cookie: ImportedCookie): Promise<void>;
    flush(): Promise<void>;
  };
  now?: () => number;
}

// Chromium stores times as microseconds since 1601-01-01 UTC.
const windowsToUnixEpochSeconds = 11_644_473_600;
// Chromium's `CookieSameSite` values in the database.
const sameSiteByValue: Record<number, ImportedCookie["sameSite"]> = {
  [-1]: "unspecified",
  0: "no_restriction",
  1: "lax",
  2: "strict",
};
const cookieWriteConcurrency = 16;
const maxProfiles = 64;

function isPermissionError(error: unknown) {
  const code = (error as NodeJS.ErrnoException | undefined)?.code;
  return code === "EPERM" || code === "EACCES";
}

function isMissing(error: unknown) {
  return (error as NodeJS.ErrnoException | undefined)?.code === "ENOENT";
}

function text(value: unknown, maxLength: number) {
  return typeof value === "string" && value.trim()
    ? value.trim().slice(0, maxLength)
    : undefined;
}

/**
 * Lists the profiles of every supported browser found on this Mac, the most
 * recently used first. A browser that macOS will not let Comma read is listed
 * last, so the user can see why it cannot be imported.
 */
export async function listBrowserImportProfiles(
  platform: Pick<BrowserImportPlatform, "appIcon" | "applicationSupportDirectory">
): Promise<BrowserImportProfile[]> {
  const profiles: Array<BrowserImportProfile & { activeTime: number }> = [];
  for (const [source, browser] of Object.entries(chromiumBrowsers) as Array<
    [BrowserImportSource, ChromiumBrowser]
  >) {
    const root = join(platform.applicationSupportDirectory, browser.directory);
    let localState: unknown;
    try {
      localState = JSON.parse(await readFile(join(root, "Local State"), "utf8"));
    } catch (error) {
      if (isPermissionError(error)) {
        const icon = await platform
          .appIcon?.(browser.bundleName)
          .catch(() => undefined);
        profiles.push({
          source,
          appName: browser.appName,
          profileDirectory: "Default",
          profileName: browser.appName,
          ...(icon ? { icon } : {}),
          status: "permission-required",
          activeTime: -1,
        });
      }
      continue;
    }
    const infoCache = (localState as { profile?: { info_cache?: unknown } })?.profile
      ?.info_cache;
    if (!infoCache || typeof infoCache !== "object") continue;
    const icon = await platform.appIcon?.(browser.bundleName).catch(() => undefined);
    for (const [profileDirectory, info] of Object.entries(infoCache)) {
      if (
        !browserImportProfileRefSchema.safeParse({ source, profileDirectory }).success
      )
        continue;
      const record = info as Record<string, unknown>;
      const userName = text(record.user_name, 256);
      profiles.push({
        source,
        appName: browser.appName,
        profileDirectory,
        profileName: text(record.name, 256) ?? profileDirectory,
        ...(userName ? { userName } : {}),
        ...(icon ? { icon } : {}),
        status: "ready",
        // Chromium records when each profile was last active, in seconds.
        activeTime: typeof record.active_time === "number" ? record.active_time : 0,
      });
    }
  }
  return profiles
    .toSorted((left, right) => right.activeTime - left.activeTime)
    .slice(0, maxProfiles)
    .map(({ activeTime: _activeTime, ...profile }) => profile);
}

/** The AES key that encrypts a profile's cookie values on macOS. */
export function chromiumCookieKey(password: string) {
  return pbkdf2Sync(password, "saltysalt", 1003, 16, "sha1");
}

/**
 * Decrypts one `encrypted_value`. Database version 24 and later put the
 * SHA-256 of the cookie's host key in front of the value, which binds the value
 * to its row. A value that fails that check is not used.
 */
export function decryptChromiumCookieValue(
  encrypted: Uint8Array,
  key: Buffer,
  hostKey: string,
  databaseVersion: number
): string | undefined {
  if (encrypted.byteLength <= 3) return undefined;
  if (Buffer.from(encrypted.subarray(0, 3)).toString("latin1") !== "v10")
    return undefined;
  try {
    const decipher = createDecipheriv("aes-128-cbc", key, Buffer.alloc(16, 0x20));
    let plain = Buffer.concat([
      decipher.update(encrypted.subarray(3)),
      decipher.final(),
    ]);
    if (databaseVersion >= 24) {
      const digest = createHash("sha256").update(hostKey).digest();
      if (plain.byteLength < digest.byteLength || !plain.subarray(0, 32).equals(digest))
        return undefined;
      plain = plain.subarray(32);
    }
    return plain.toString("utf8");
  } catch {
    return undefined;
  }
}

// Integer columns are read as `bigint`: `expires_utc` is larger than 2^53.
interface CookieRow {
  host_key: string;
  top_frame_site_key: string;
  name: string;
  value: string;
  encrypted_value: Uint8Array;
  path: string;
  expires_utc: bigint;
  last_access_utc: bigint;
  is_secure: bigint;
  is_httponly: bigint;
  has_expires: bigint;
  is_persistent: bigint;
  samesite: bigint;
}

function cookieKey(
  domainOrHostKey: string,
  hostOnly: boolean,
  path: string,
  name: string
) {
  const host = domainOrHostKey.replace(/^\./u, "").toLowerCase();
  return `${hostOnly ? host : `.${host}`}|${path}|${name}`;
}

async function copyIfPresent(source: string, destination: string) {
  try {
    await writeFile(destination, await readFile(source), { mode: 0o600 });
  } catch (error) {
    if (!isMissing(error)) throw error;
  }
}

type CookieDatabase =
  | { status: "found"; path: string }
  | { status: "failed" | "not-found" | "permission-required" };

async function findCookieDatabase({
  applicationSupportDirectory,
  profile,
}: {
  applicationSupportDirectory: string;
  profile: BrowserImportProfileRef;
}): Promise<CookieDatabase> {
  const profileRoot = join(
    applicationSupportDirectory,
    chromiumBrowsers[profile.source].directory,
    profile.profileDirectory
  );
  for (const path of [
    join(profileRoot, "Cookies"),
    join(profileRoot, "Network", "Cookies"),
  ]) {
    try {
      // Opening the file is also the check macOS applies to another app's data.
      await (await open(path, "r")).close();
      return { status: "found", path };
    } catch (error) {
      if (isPermissionError(error)) return { status: "permission-required" };
      if (!isMissing(error)) return { status: "failed" };
    }
  }
  return { status: "not-found" };
}

async function readCookieRows(databasePath: string, temporaryDirectory: string) {
  // Chromium keeps the live database open. Read a private copy, together with
  // its rollback journal, so SQLite can finish an interrupted write first.
  const folder = await mkdtemp(join(temporaryDirectory, "comma-cookie-import-"));
  try {
    const copy = join(folder, "Cookies");
    await writeFile(copy, await readFile(databasePath), { mode: 0o600 });
    await copyIfPresent(`${databasePath}-journal`, `${copy}-journal`);
    const database = new DatabaseSync(copy);
    try {
      const meta = database
        .prepare("SELECT value FROM meta WHERE key = 'version'")
        .get() as { value?: string } | undefined;
      const statement = database.prepare(
        `SELECT host_key, top_frame_site_key, name, value, encrypted_value, path,
           expires_utc, last_access_utc, is_secure, is_httponly, has_expires,
           is_persistent, samesite
         FROM cookies`
      );
      statement.setReadBigInts(true);
      const rows = statement.all() as unknown as CookieRow[];
      return { rows, version: Number(meta?.value ?? 0) };
    } finally {
      database.close();
    }
  } finally {
    await rm(folder, { force: true, recursive: true });
  }
}

function unixSeconds(chromiumMicroseconds: bigint) {
  return Number(chromiumMicroseconds / 1_000_000n) - windowsToUnixEpochSeconds;
}

/** A cookie's site: its registrable domain, or the host when it has none. */
function cookieSite(hostKey: string) {
  const host = hostKey.replace(/^\./u, "").toLowerCase();
  return getDomain(host, { allowPrivateDomains: true }) ?? host;
}

type ProfileRead =
  | {
      status: "read";
      key: Buffer;
      rows: CookieRow[];
      version: number;
    }
  | { status: "failed" | "keychain-denied" | "not-found" | "permission-required" };

async function readProfile(
  platform: BrowserImportPlatform,
  profile: BrowserImportProfileRef,
  passwords: Map<BrowserImportSource, Promise<KeychainPasswordRead>>
): Promise<ProfileRead> {
  const browser = chromiumBrowsers[profile.source];
  const database = await findCookieDatabase({
    applicationSupportDirectory: platform.applicationSupportDirectory,
    profile,
  });
  if (database.status !== "found") return { status: database.status };

  // The profiles of one browser share its keychain item: macOS asks once.
  let password = passwords.get(profile.source);
  if (!password) {
    password = platform.readKeychainPassword(
      browser.keychainService,
      browser.keychainAccount
    );
    passwords.set(profile.source, password);
  }
  const secret = await password;
  if (secret.status === "denied") return { status: "keychain-denied" };
  if (secret.status !== "found") return { status: "failed" };
  try {
    const read = await readCookieRows(database.path, platform.temporaryDirectory);
    return { status: "read", key: chromiumCookieKey(secret.password), ...read };
  } catch (error) {
    return { status: isPermissionError(error) ? "permission-required" : "failed" };
  }
}

/**
 * Copies the cookies of the selected profiles into the browser sidebar. For
 * each site, the profile that used it most recently provides all of its
 * cookies, so the sign-ins of two accounts of one site are never mixed.
 * Cookies that the sidebar already has stay as they are, so an account the
 * user signed in to in Comma is not replaced; one with the same value, from an
 * earlier import, counts as unchanged. Partitioned cookies are skipped because
 * Electron cannot store their partition key. The result also counts sites, the
 * unit the user sees: sites that got a cookie, and sites the sidebar kept.
 */
export async function importBrowserCookies(
  platform: BrowserImportPlatform,
  input: BrowserCookieImportInput
): Promise<BrowserCookieImportResult> {
  const parsed = browserCookieImportInputSchema.parse(input);
  const profiles = [
    ...new Map(
      parsed.profiles.map((profile) => [
        `${profile.source}/${profile.profileDirectory}`,
        profile,
      ])
    ).values(),
  ];
  const passwords = new Map<BrowserImportSource, Promise<KeychainPasswordRead>>();
  const read: Array<
    Extract<ProfileRead, { status: "read" }> & { ref: BrowserImportProfileRef }
  > = [];
  const unread: Array<
    BrowserImportProfileRef & { status: Exclude<ProfileRead["status"], "read"> }
  > = [];
  for (const profile of profiles) {
    const outcome = await readProfile(platform, profile, passwords);
    if (outcome.status === "read") read.push({ ...outcome, ref: profile });
    else unread.push({ ...profile, status: outcome.status });
  }
  if (read.length === 0) return { status: unread[0]!.status };

  // The profile that used each site last. A tie keeps the earlier profile.
  const owner = new Map<string, { at: bigint; profile: number }>();
  for (const [index, profile] of read.entries()) {
    for (const row of profile.rows) {
      if (row.top_frame_site_key) continue;
      const site = cookieSite(String(row.host_key));
      const current = owner.get(site);
      if (!current || row.last_access_utc > current.at) {
        owner.set(site, { at: row.last_access_utc, profile: index });
      }
    }
  }

  const existing = new Map(
    (await platform.cookies.list()).map((cookie) => [
      cookieKey(cookie.domain, cookie.hostOnly, cookie.path, cookie.name),
      cookie.value,
    ])
  );
  const nowSeconds = (platform.now?.() ?? Date.now()) / 1000;
  const result = {
    status: "imported" as const,
    imported: 0,
    importedSites: 0,
    keptSites: 0,
    unchangedSites: 0,
    unchanged: 0,
    skippedExisting: 0,
    skippedExpired: 0,
    skippedUnsupported: 0,
    failed: 0,
    profiles: [] as Array<
      BrowserImportProfileRef & {
        importedSites: number;
        keptSites: number;
        unchangedSites: number;
      }
    >,
    unread,
  };
  const cookies: Array<ImportedCookie & { site: string }> = [];
  const keptSites = new Set<string>();
  const unchangedSites = new Set<string>();
  for (const [index, profile] of read.entries()) {
    for (const row of profile.rows) {
      const hostKey = String(row.host_key);
      // A site with only partitioned cookies has no owner; they are skipped below.
      const site = owner.get(cookieSite(hostKey));
      if (site && site.profile !== index) continue;
      const path = String(row.path || "/");
      if (row.top_frame_site_key) {
        result.skippedUnsupported += 1;
        continue;
      }
      const persistent = row.has_expires === 1n && row.is_persistent === 1n;
      const expirationDate = unixSeconds(row.expires_utc);
      if (persistent && expirationDate <= nowSeconds) {
        result.skippedExpired += 1;
        continue;
      }
      const hostOnly = !hostKey.startsWith(".");
      const value =
        row.value ||
        decryptChromiumCookieValue(
          row.encrypted_value,
          profile.key,
          hostKey,
          profile.version
        );
      if (value === undefined) {
        result.skippedUnsupported += 1;
        continue;
      }
      const stored = existing.get(cookieKey(hostKey, hostOnly, path, row.name));
      if (stored === value) {
        result.unchanged += 1;
        unchangedSites.add(cookieSite(hostKey));
        continue;
      }
      if (stored !== undefined) {
        result.skippedExisting += 1;
        keptSites.add(cookieSite(hostKey));
        continue;
      }
      const secure = row.is_secure === 1n;
      cookies.push({
        url: `${secure ? "https" : "http"}://${hostKey.replace(/^\./u, "")}${path}`,
        name: row.name,
        value,
        ...(hostOnly ? {} : { domain: hostKey }),
        path,
        secure,
        httpOnly: row.is_httponly === 1n,
        sameSite: sameSiteByValue[Number(row.samesite)] ?? "unspecified",
        ...(persistent ? { expirationDate } : {}),
        site: cookieSite(hostKey),
      });
    }
    profile.key.fill(0);
  }

  const importedSites = new Set<string>();
  for (let index = 0; index < cookies.length; index += cookieWriteConcurrency) {
    const batch = cookies.slice(index, index + cookieWriteConcurrency);
    const outcomes = await Promise.allSettled(
      batch.map(({ site: _site, ...cookie }) => platform.cookies.set(cookie))
    );
    for (const [position, outcome] of outcomes.entries()) {
      if (outcome.status === "fulfilled") {
        result.imported += 1;
        importedSites.add(batch[position]!.site);
      } else result.failed += 1;
    }
  }
  // Each site counts once, by what happened to it, under the profile that
  // provided it: imported, else kept, else unchanged.
  result.profiles = read.map(({ ref }) => ({
    ...ref,
    importedSites: 0,
    keptSites: 0,
    unchangedSites: 0,
  }));
  const countSites = (
    sites: Iterable<string>,
    field: "importedSites" | "keptSites" | "unchangedSites",
    skip: (site: string) => boolean = () => false
  ) => {
    for (const site of sites) {
      const profile = owner.get(site)?.profile;
      if (profile === undefined || skip(site)) continue;
      result[field] += 1;
      result.profiles[profile]![field] += 1;
    }
  };
  countSites(importedSites, "importedSites");
  countSites(keptSites, "keptSites", (site) => importedSites.has(site));
  countSites(
    unchangedSites,
    "unchangedSites",
    (site) => importedSites.has(site) || keptSites.has(site)
  );
  if (result.imported > 0) await platform.cookies.flush();
  return result;
}

interface ElectronCookieStore {
  get(filter: Record<string, never>): Promise<
    Array<{
      domain?: string;
      hostOnly?: boolean;
      name: string;
      path?: string;
      value: string;
    }>
  >;
  set(details: ImportedCookie): Promise<void>;
  flushStore(): Promise<void>;
}

/** Imports into the cookie store of the browser sidebar partition. */
export function electronBrowserImportPlatform({
  appIcon,
  applicationSupportDirectory,
  cookies,
  readKeychainPassword,
  temporaryDirectory,
}: {
  appIcon?: BrowserImportPlatform["appIcon"];
  applicationSupportDirectory: string;
  cookies: ElectronCookieStore;
  readKeychainPassword: BrowserImportPlatform["readKeychainPassword"];
  temporaryDirectory: string;
}): BrowserImportPlatform {
  return {
    appIcon,
    applicationSupportDirectory,
    temporaryDirectory,
    readKeychainPassword,
    cookies: {
      list: async () =>
        (await cookies.get({})).map((cookie) => ({
          domain: cookie.domain ?? "",
          hostOnly: cookie.hostOnly ?? false,
          name: cookie.name,
          path: cookie.path ?? "/",
          value: cookie.value,
        })),
      set: (cookie) => cookies.set(cookie),
      flush: () => cookies.flushStore(),
    },
  };
}
