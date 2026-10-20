import "@comma/test-utils/browser-commands";
import { setUpDeterminism } from "./record";
import { installTesterClock } from "./tester-clock";
import { installTesterHarness } from "./tester-harness";

// React Aria's virtualizer skips measuring under NODE_ENV=test unless
// process.env.VIRT_ON is set. Real layout here measures as the app does, in
// the component tests that render in this frame (./child sets it for pages).
const scope = globalThis as { process?: { env: Record<string, string | undefined> } };
scope.process ??= { env: {} };
scope.process.env.VIRT_ON = "1";

// The determinism proof slows the CPU on some runs (./record).
await setUpDeterminism();

// Each test's frame runs on the deterministic harness (./tester-harness) and
// the test clock (./tester-clock), whose hooks run after the harness's.
installTesterHarness();
installTesterClock();
