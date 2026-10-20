// Waits for a condition that work in progress (a fiber, file I/O) makes true, by attempts rather than time.
/** Asks `request` until `done` says its JSON answer is the last one. */
export async function until(request: () => Promise<Response>, done: (body: any, status: number) => boolean, what: string) {
  for (let attempt = 0; attempt < 100_000; attempt++) {
    const response = await request();
    const body = await response.json().catch(() => null);
    if (done(body, response.status)) return body;
    await new Promise((resolve) => setImmediate(resolve));
  }
  throw new Error(`${what} did not settle`);
}

/** Waits until `check` holds. */
export async function eventually(check: () => boolean | Promise<boolean>, what: string) {
  for (let attempt = 0; attempt < 100_000; attempt++) {
    if (await check()) return;
    await new Promise((resolve) => setImmediate(resolve));
  }
  throw new Error(`${what} did not happen`);
}
