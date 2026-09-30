export interface CoalescedAsyncRenderInput {
  /** Document identity and every non-source render option (theme, language). */
  scopeKey: string;
  source: string;
}

/**
 * One asynchronous block renderer with one replaceable next input.
 *
 * A completed prefix remains useful while the same document keeps growing.
 * Changing its scope or replacing the source invalidates the old result, but
 * does not start another worker operation until the current one settles.
 * A stalled worker claims no progress; this queue adds no timer or retry.
 *
 * Ordering, disposal, and latest-input progress (assuming worker settlement)
 * map to `tla/salix/MarkdownAsyncRender.tla`.
 */
export function createCoalescedAsyncRender<
  Input extends CoalescedAsyncRenderInput,
  Result,
>({
  render,
  onResult,
  onError,
}: {
  render(input: Input): Promise<Result>;
  onResult(result: Result, input: Input): void;
  onError(error: unknown, input: Input): void;
}) {
  let disposed = false;
  let generation = 0;
  let current: Input | undefined;
  let pending: Input | undefined;
  let inFlight: { input: Input; generation: number } | undefined;

  const drain = () => {
    if (disposed || inFlight || !pending) return;
    const operation = { input: pending, generation };
    pending = undefined;
    inFlight = operation;

    const currentResult = () =>
      !disposed &&
      operation.generation === generation &&
      current?.scopeKey === operation.input.scopeKey &&
      current.source.startsWith(operation.input.source);
    const finish = () => {
      inFlight = undefined;
      drain();
    };

    // Normalize a synchronous renderer failure through the same settlement
    // path. There is no recurring scheduling while no input is pending.
    void Promise.resolve()
      .then(() => render(operation.input))
      .then(
        (result) => {
          try {
            if (currentResult()) onResult(result, operation.input);
          } finally {
            finish();
          }
        },
        (error: unknown) => {
          try {
            // An obsolete prefix failure must not replace the next prefix's
            // content with an error. The latest input still gets its attempt.
            if (currentResult() && current?.source === operation.input.source) {
              onError(error, operation.input);
            }
          } finally {
            finish();
          }
        }
      );
  };

  return {
    update(input: Input) {
      if (disposed) return;
      if (current?.scopeKey === input.scopeKey && current.source === input.source) {
        return;
      }
      if (
        !current ||
        current.scopeKey !== input.scopeKey ||
        !input.source.startsWith(current.source)
      ) {
        generation += 1;
      }
      current = input;
      pending = input;
      drain();
    },
    dispose() {
      disposed = true;
      current = undefined;
      pending = undefined;
    },
  };
}
