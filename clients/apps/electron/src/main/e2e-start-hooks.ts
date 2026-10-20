/**
 * The e2e hooks (`e2e-hooks.ts`) Main reads each time it starts its services, by their environment variables. A reset
 * of a worker's shared e2e app takes the next test's own (`commaE2eCore.reset(env)`); every other hook is its launch's.
 */
export const electronE2eStartHookEnv = [
  "COMMA_ELECTRON_E2E_BROWSER_IMPORT_DIRECTORY",
  "COMMA_ELECTRON_E2E_BROWSER_IMPORT_KEYCHAIN_PASSWORD",
  "COMMA_ELECTRON_E2E_CABLE_PHONE_ORIGIN",
  "COMMA_ELECTRON_E2E_COMPUTE_NODE_LIFECYCLE_PATH",
  "COMMA_ELECTRON_E2E_CORE_TEST_CLOCK",
  "COMMA_ELECTRON_E2E_STATION_PEERS",
  "COMMA_ELECTRON_E2E_SYNCHRONICITY_MODE",
  "COMMA_ELECTRON_E2E_UPDATE_FEED",
] as const;

export type ElectronE2eStartHookEnv = Partial<
  Record<(typeof electronE2eStartHookEnv)[number], string>
>;
