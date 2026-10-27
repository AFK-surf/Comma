import { createCipheriv, createHash, pbkdf2Sync } from "node:crypto";
import { chmod, mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { afterEach, describe, expect, it } from "vitest";
import { realMainClock } from "../clock";
import {
  importBrowserCookies,
  listBrowserImportProfiles,
  type BrowserImportPlatform,
  type ImportedCookie,
} from "../modules/browser-sidebar/browser-import";

const password = "chrome-safe-storage-password";
const now = Date.UTC(2026, 9, 6);
// Chromium time: microseconds since 1601-01-01 UTC.
const chromiumTime = (unixMs: number) => (BigInt(unixMs) + 11_644_473_600_000n) * 1000n;

function encrypt(value: string, hostKey: string, version: number) {
  const key = pbkdf2Sync(password, "saltysalt", 1003, 16, "sha1");
  const cipher = createCipheriv("aes-128-cbc", key, Buffer.alloc(16, 0x20));
  const plain = Buffer.concat([
    version >= 24 ? createHash("sha256").update(hostKey).digest() : Buffer.alloc(0),
    Buffer.from(value),
  ]);
  return Buffer.concat([Buffer.from("v10"), cipher.update(plain), cipher.final()]);
}

interface Row {
  host: string;
  name: string;
  value: string;
  path?: string;
  expires?: number;
  secure?: boolean;
  httpOnly?: boolean;
  sameSite?: number;
  partition?: string;
  encrypted?: Buffer;
  lastAccess?: number;
}

async function writeCookieDatabase(profileFolder: string, rows: Row[], version = 24) {
  await mkdir(profileFolder, { recursive: true });
  const database = new DatabaseSync(join(profileFolder, "Cookies"));
  database.exec(`
    CREATE TABLE meta(key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR);
    CREATE TABLE cookies(host_key TEXT NOT NULL, top_frame_site_key TEXT NOT NULL,
      name TEXT NOT NULL, value TEXT NOT NULL, encrypted_value BLOB NOT NULL,
      path TEXT NOT NULL, expires_utc INTEGER NOT NULL, last_access_utc INTEGER NOT NULL,
      is_secure INTEGER NOT NULL,
      is_httponly INTEGER NOT NULL, has_expires INTEGER NOT NULL,
      is_persistent INTEGER NOT NULL, samesite INTEGER NOT NULL);
  `);
  database.prepare("INSERT INTO meta VALUES ('version', ?)").run(String(version));
  const insert = database.prepare(
    "INSERT INTO cookies VALUES (?, ?, ?, '', ?, ?, ?, ?, ?, ?, ?, ?, ?)"
  );
  for (const row of rows) {
    const persistent = row.expires !== undefined;
    insert.run(
      row.host,
      row.partition ?? "",
      row.name,
      row.encrypted ?? encrypt(row.value, row.host, version),
      row.path ?? "/",
      persistent ? chromiumTime(row.expires!) : 0n,
      chromiumTime(row.lastAccess ?? now - 60_000),
      row.secure ? 1 : 0,
      row.httpOnly ? 1 : 0,
      persistent ? 1 : 0,
      persistent ? 1 : 0,
      row.sameSite ?? -1
    );
  }
  database.close();
}

async function writeChromeProfile(
  root: string,
  rows: Row[],
  {
    version = 24,
    profiles = { Default: rows },
  }: {
    version?: number;
    profiles?: Record<string, Row[]>;
  } = {}
) {
  const browser = join(root, "Google/Chrome");
  await mkdir(browser, { recursive: true });
  await writeFile(
    join(browser, "Local State"),
    JSON.stringify({
      profile: {
        info_cache: {
          Default: { name: "Person 1", user_name: "ada@example.com" },
          "Profile 2": { name: "Work" },
        },
      },
    })
  );
  for (const [directory, profileRows] of Object.entries(profiles)) {
    await writeCookieDatabase(join(browser, directory), profileRows, version);
  }
}

const chromeDefault = { source: "chrome", profileDirectory: "Default" } as const;

function testPlatform(
  root: string,
  overrides: Partial<BrowserImportPlatform> = {}
): BrowserImportPlatform & { stored: ImportedCookie[]; flushes: number } {
  const platform = {
    stored: [] as ImportedCookie[],
    flushes: 0,
    applicationSupportDirectory: root,
    temporaryDirectory: root,
    clock: { ...realMainClock, now: () => now },
    readKeychainPassword: async () => ({ status: "found" as const, password }),
    cookies: {
      list: async () => [
        {
          domain: ".kept.example",
          hostOnly: false,
          name: "session",
          path: "/",
          value: "signed-in-here",
        },
        {
          domain: ".again.example",
          hostOnly: false,
          name: "session",
          path: "/",
          value: "imported-before",
        },
      ],
      set: async (cookie: ImportedCookie) => {
        platform.stored.push(cookie);
      },
      flush: async () => {
        platform.flushes += 1;
      },
    },
    ...overrides,
  };
  return platform;
}

const roots: string[] = [];
async function newRoot() {
  const root = await mkdtemp(join(tmpdir(), "comma-browser-import-"));
  roots.push(root);
  return root;
}

afterEach(async () => {
  for (const root of roots.splice(0)) {
    await chmod(join(root, "Google/Chrome"), 0o700).catch(() => undefined);
    await rm(root, { force: true, recursive: true });
  }
});

describe("browser cookie import", () => {
  it("lists the profiles of a browser with its app icon, and marks one macOS will not let Comma read", async () => {
    const root = await newRoot();
    await writeChromeProfile(root, []);
    const icon = "data:image/png;base64,iVBORw0KGgo=";
    const appIcon = async (bundleName: string) =>
      bundleName === "Google Chrome.app" ? icon : undefined;
    expect(
      await listBrowserImportProfiles({ appIcon, applicationSupportDirectory: root })
    ).toEqual([
      {
        source: "chrome",
        appName: "Google Chrome",
        profileDirectory: "Default",
        profileName: "Person 1",
        userName: "ada@example.com",
        icon,
        status: "ready",
      },
      {
        source: "chrome",
        appName: "Google Chrome",
        profileDirectory: "Profile 2",
        profileName: "Work",
        icon,
        status: "ready",
      },
    ]);

    await chmod(join(root, "Google/Chrome"), 0o000);
    expect(
      await listBrowserImportProfiles({ applicationSupportDirectory: root })
    ).toEqual([
      expect.objectContaining({ source: "chrome", status: "permission-required" }),
    ]);
  });

  it("copies the cookies a sign-in needs, and leaves the rest", async () => {
    const root = await newRoot();
    const future = now + 30 * 24 * 3600 * 1000;
    await writeChromeProfile(root, [
      {
        host: "app.example.com",
        name: "sid",
        value: "signed-in",
        expires: future,
        secure: true,
        httpOnly: true,
        sameSite: 1,
      },
      { host: ".example.com", name: "prefs", value: "dark", path: "/account" },
      { host: ".kept.example", name: "session", value: "from-chrome", expires: future },
      {
        host: ".again.example",
        name: "session",
        value: "imported-before",
        expires: future,
      },
      { host: "old.example.com", name: "gone", value: "x", expires: now - 1000 },
      {
        host: "embed.example",
        name: "chips",
        value: "x",
        expires: future,
        partition: "https://top.example",
      },
      {
        host: "moved.example",
        name: "copied",
        value: "x",
        encrypted: encrypt("x", "another.example", 24),
      },
    ]);
    const platform = testPlatform(root);

    expect(await importBrowserCookies(platform, { profiles: [chromeDefault] })).toEqual(
      {
        status: "imported",
        imported: 2,
        importedSites: 1,
        keptSites: 1,
        unchangedSites: 1,
        unchanged: 1,
        skippedExisting: 1,
        skippedExpired: 1,
        skippedUnsupported: 2,
        failed: 0,
        profiles: [
          { ...chromeDefault, importedSites: 1, keptSites: 1, unchangedSites: 1 },
        ],
        unread: [],
      }
    );
    expect(platform.stored).toEqual([
      {
        url: "https://app.example.com/",
        name: "sid",
        value: "signed-in",
        path: "/",
        secure: true,
        httpOnly: true,
        sameSite: "lax",
        expirationDate: Math.floor(future / 1000),
      },
      {
        url: "http://example.com/account",
        name: "prefs",
        value: "dark",
        domain: ".example.com",
        path: "/account",
        secure: false,
        httpOnly: false,
        sameSite: "unspecified",
      },
    ]);
    expect(platform.flushes).toBe(1);
  });

  it("reads databases written before values were bound to their host", async () => {
    const root = await newRoot();
    await writeChromeProfile(root, [{ host: "example.com", name: "a", value: "1" }], {
      version: 23,
    });
    const platform = testPlatform(root);

    await importBrowserCookies(platform, { profiles: [chromeDefault] });

    expect(platform.stored).toEqual([
      expect.objectContaining({ name: "a", value: "1" }),
    ]);
  });

  it("stops when the user denies the keychain prompt, and accepts only a profile folder name", async () => {
    const root = await newRoot();
    await writeChromeProfile(root, [{ host: "example.com", name: "a", value: "1" }]);
    const platform = testPlatform(root, {
      readKeychainPassword: async () => ({ status: "denied" }),
    });

    expect(await importBrowserCookies(platform, { profiles: [chromeDefault] })).toEqual(
      {
        status: "keychain-denied",
      }
    );
    expect(platform.stored).toEqual([]);
    await expect(
      importBrowserCookies(platform, {
        profiles: [{ source: "chrome", profileDirectory: ".." }],
      })
    ).rejects.toThrow();
  });

  it("takes each site from the profile that used it last, and asks each browser's keychain once", async () => {
    const root = await newRoot();
    const earlier = now - 3_600_000;
    await writeChromeProfile(root, [], {
      profiles: {
        Default: [
          {
            host: "github.com",
            name: "user_session",
            value: "ada",
            lastAccess: earlier,
          },
          { host: ".github.com", name: "logged_in", value: "yes", lastAccess: earlier },
          { host: "news.example.org", name: "sid", value: "ada", lastAccess: earlier },
        ],
        "Profile 2": [
          { host: "github.com", name: "user_session", value: "work" },
          { host: "gist.github.com", name: "_gist", value: "work" },
        ],
      },
    });
    await writeCookieDatabase(join(root, "Arc/User Data/Default"), [
      { host: "arc.example", name: "sid", value: "x" },
    ]);
    const keychainReads: string[] = [];
    const platform = testPlatform(root, {
      readKeychainPassword: async (service) => {
        keychainReads.push(service);
        return service === "Arc Safe Storage"
          ? { status: "denied" }
          : { status: "found", password };
      },
    });

    const result = await importBrowserCookies(platform, {
      profiles: [
        chromeDefault,
        { source: "chrome", profileDirectory: "Profile 2" },
        { source: "arc", profileDirectory: "Default" },
      ],
    });

    expect(result).toMatchObject({
      status: "imported",
      imported: 3,
      importedSites: 2,
      profiles: [
        { ...chromeDefault, importedSites: 1 },
        { source: "chrome", profileDirectory: "Profile 2", importedSites: 1 },
      ],
      unread: [
        { source: "arc", profileDirectory: "Default", status: "keychain-denied" },
      ],
    });
    // The work account used GitHub last; none of the other account's GitHub
    // cookies join it.
    expect(
      platform.stored
        .map(({ name, url, value }) => ({ name, url, value }))
        .toSorted((left, right) => left.url.localeCompare(right.url))
    ).toEqual([
      { name: "_gist", url: "http://gist.github.com/", value: "work" },
      { name: "user_session", url: "http://github.com/", value: "work" },
      { name: "sid", url: "http://news.example.org/", value: "ada" },
    ]);
    expect(keychainReads).toEqual(["Chrome Safe Storage", "Arc Safe Storage"]);
  });
});
