// The names realms of a world put in URLs.

/**
 * Names a request to the realm that answers it (./realm-http.ts):
 * `<realm>.<n>`, the n-th request the realm made. The last parameter of the
 * request's URL on the wire; the answering realm removes it before its server
 * sees the request.
 */
export const worldRequestParameter = "comma-world-request";
/**
 * On an answer of the realm that is none of its server's: the realm sends the
 * request back, and the realm that made it sends it again (./node-realm.ts,
 * makeRoom).
 */
export const worldAgainHeader = "comma-world-again";
/**
 * Before `worldRequestParameter` in the URL of a request of the wire's own:
 * the browser failed the request so named before any answer, and its realm
 * says so to the realm that would wait for it (./realm-http.ts).
 */
export const worldLostParameter = "comma-world-lost";

// What a page writes in the URL of a worker that is a realm of its world
// (./worker-realm.ts reads it).
export const workerRealmParameter = "comma-realm";
/** In the query of a worker script of the shipped web build: the test server puts the realm's modules before it. */
export const workerPreludeParameter = "comma-worker-prelude";
/** The page's HTTP routes when it started the worker, as JSON. */
export const workerRoutesParameter = "comma-realm-routes";
/** The realm a worker's line goes to, when not its page (a frame's worker, ./frame-realm.ts). */
export const workerPeerParameter = "comma-realm-peer";
/** A sandboxed frame's first message to its page: it is a realm (./frame-realm.ts). */
export const frameHello = "comma-frame-hello";
