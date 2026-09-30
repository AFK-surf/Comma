export function acceptedSendPromise(result: unknown): Promise<unknown> | undefined {
  if (!result || (typeof result !== "object" && typeof result !== "function")) {
    return undefined;
  }
  // Only the explicit bridge admission promise may cancel a launch. The web
  // channel returns a plain completion promise after publishing its pending
  // row synchronously; a later transport rejection must settle as a failed
  // destination without tearing down the in-flight presentation.
  const accepted = (result as { accepted?: unknown }).accepted;
  if (
    !accepted ||
    (typeof accepted !== "object" && typeof accepted !== "function") ||
    typeof (accepted as PromiseLike<unknown>).then !== "function"
  ) {
    return undefined;
  }
  return Promise.resolve(accepted);
}
