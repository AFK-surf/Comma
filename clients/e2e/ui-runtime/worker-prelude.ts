// What runs first in a worker of the shipped web build (apps/web/dist), as
// the test server gives the worker's script to a page (vitest.config.ts,
// servedWebApp): the same two modules the test build puts first in its own
// workers (seedWorkerEntries).
import "../app-shell/support/worker-seed";
import "./worker-realm";
