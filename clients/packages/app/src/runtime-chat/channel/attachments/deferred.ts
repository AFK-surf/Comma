export type Deferred<T> = {
  promise: Promise<T>;
  resolve(value: T): void;
};

/** A promise plus its resolver, for signalling across an await boundary. */
export function deferred<T = void>(): Deferred<T> {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((settle) => {
    resolve = settle;
  });
  return { promise, resolve };
}
