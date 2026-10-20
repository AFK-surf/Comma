import { beforeEach } from "vitest";
import { forbidRealIo, watchRealIo } from "./io-guard";
import { keepTemporaryFilesInMemory } from "./memory-tmp";
import { seedRandomPerTest } from "./seeded-random";
import { recordUnitTests } from "./unit-record";
import { installTestClock, resetTestClock } from "./test-clock";

// Before the fake clock, so only timers on the machine's clock are counted.
// Its record writes with the file system as it was (./unit-record).
recordUnitTests();
watchRealIo();
keepTemporaryFilesInMemory();
seedRandomPerTest();
// The deterministic unit suite: real IO fails the test (./io-guard).
forbidRealIo();

// The first setup file, so the fake clock is in place before React and the
// other libraries load and keep the timer functions they find (test-clock.ts).
installTestClock();

beforeEach(() => {
  resetTestClock();
});
