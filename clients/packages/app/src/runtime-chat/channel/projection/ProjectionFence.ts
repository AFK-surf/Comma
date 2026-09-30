/**
 * Whether Main projects this channel's session, and which projection
 * generation it is in. A session that goes missing ends its generation, and
 * with it every pick started under that generation.
 */
export class ProjectionFence {
  #generation = 0;
  #hasSeenSession = false;

  get generation() {
    return this.#generation;
  }

  get hasSeenSession() {
    return this.#hasSeenSession;
  }

  /** Main projected the session. */
  see() {
    this.#hasSeenSession = true;
  }

  /** Main stopped projecting the session. */
  end() {
    this.#generation += 1;
    this.#hasSeenSession = false;
  }

  assertCurrent(generation: number) {
    if (!this.#hasSeenSession || generation !== this.#generation) {
      throw new Error("Chat bridge is not retained.");
    }
  }
}
