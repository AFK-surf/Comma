// Runs first in each worker of the test build (vitest.config.ts,
// appShellPagesBuild): the worker draws its random numbers from the seed its
// page gave it in its URL (./random).
import { installSeededRandom, workerSeedParameter } from "./random";

const seed = new URLSearchParams(self.location.hash.slice(1)).get(workerSeedParameter);
if (seed === null)
  throw new Error(
    "A test build worker started without its seed (./random seedWorkers)."
  );
installSeededRandom(self, Number(seed));
