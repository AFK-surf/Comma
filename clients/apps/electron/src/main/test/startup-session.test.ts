import { describe, expect, it } from "vitest";
import { resolveElectronStartupSession } from "../startup-session";

const readLocalDevSessionFile = () =>
  JSON.stringify({
    apiBaseUrl: "http://127.0.0.1:4200/",
    email: " Local@Example.com ",
    sessionToken: " local-session-token ",
    version: 1,
  });

describe("Electron startup Session", () => {
  it.each(["development", "test"])(
    "uses the same unpackaged Session path in NODE_ENV=%s",
    (nodeEnv) => {
      const env = {
        COMMA_ELECTRON_STARTUP_SESSION_EMAIL: " Local@Example.com ",
        COMMA_ELECTRON_STARTUP_SESSION_TOKEN: " local-session-token ",
        NODE_ENV: nodeEnv,
      };

      expect(
        resolveElectronStartupSession({
          apiBaseUrl: "http://127.0.0.1:4200",
          env,
          isPackaged: false,
        })
      ).toEqual({
        audience: "http://127.0.0.1:4200",
        email: "local@example.com",
        expiresAtEpochSeconds: 4_102_444_800,
        sessionId: "startup-session:local@example.com",
        token: "local-session-token",
        userId: "startup-user:local@example.com",
      });
      expect(env).not.toHaveProperty("COMMA_ELECTRON_STARTUP_SESSION_TOKEN");
      expect(env.NODE_ENV).toBe(nodeEnv);
    }
  );

  it("fails closed in packaged runtimes while still consuming the token", () => {
    const env = {
      COMMA_ELECTRON_STARTUP_SESSION_FILE: "/repo/.local/comma-dev-session.json",
      COMMA_ELECTRON_STARTUP_SESSION_TOKEN: "must-not-escape",
    };

    expect(
      resolveElectronStartupSession({
        apiBaseUrl: "https://api.comma.test",
        env,
        isPackaged: true,
        readFile: () => {
          throw new Error("packaged runtime must not read a development file");
        },
      })
    ).toBeUndefined();
    expect(env).not.toHaveProperty("COMMA_ELECTRON_STARTUP_SESSION_TOKEN");
  });

  it("does nothing without an explicit token", () => {
    expect(
      resolveElectronStartupSession({
        apiBaseUrl: "http://127.0.0.1:4200",
        env: {},
        isPackaged: false,
      })
    ).toBeUndefined();
  });

  it("loads the fixed gitignored development Session file when it exists", () => {
    const defaultFilePath = "/repo/.local/comma-dev-session.json";

    expect(
      resolveElectronStartupSession({
        apiBaseUrl: "http://127.0.0.1:4200",
        defaultFilePath,
        env: {},
        fileExists: (path) => path === defaultFilePath,
        isPackaged: false,
        readFile: readLocalDevSessionFile,
      })
    ).toMatchObject({
      email: "local@example.com",
      token: "local-session-token",
    });
  });

  it("does nothing when the fixed development Session file is absent", () => {
    expect(
      resolveElectronStartupSession({
        apiBaseUrl: "http://127.0.0.1:4200",
        defaultFilePath: "/repo/.local/comma-dev-session.json",
        env: {},
        fileExists: () => false,
        isPackaged: false,
        readFile: () => {
          throw new Error("an absent default file must not be read");
        },
      })
    ).toBeUndefined();
  });

  it("reuses a gitignored development Session file across Main relaunches", () => {
    const env = {
      COMMA_ELECTRON_STARTUP_SESSION_FILE: "/repo/.local/comma-dev-session.json",
    };

    const first = resolveElectronStartupSession({
      apiBaseUrl: "http://127.0.0.1:4200",
      env,
      isPackaged: false,
      readFile: readLocalDevSessionFile,
    });
    const relaunched = resolveElectronStartupSession({
      apiBaseUrl: "http://127.0.0.1:4200",
      env,
      isPackaged: false,
      readFile: readLocalDevSessionFile,
    });

    expect(relaunched).toEqual(first);
    expect(env.COMMA_ELECTRON_STARTUP_SESSION_FILE).toBe(
      "/repo/.local/comma-dev-session.json"
    );
  });

  it("rejects a development Session file for another API", () => {
    expect(() =>
      resolveElectronStartupSession({
        apiBaseUrl: "http://127.0.0.1:4200",
        env: {
          COMMA_ELECTRON_STARTUP_SESSION_FILE: "/repo/.local/comma-dev-session.json",
        },
        isPackaged: false,
        readFile: () =>
          JSON.stringify({
            apiBaseUrl: "http://127.0.0.1:4300",
            email: "comma-local@example.com",
            sessionToken: "local-session-token",
            version: 1,
          }),
      })
    ).toThrow("targets http://127.0.0.1:4300");
  });
});
