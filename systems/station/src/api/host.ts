// The machine's state (host.rs `info`), read in a reader and kept here: given again within ten seconds, and the CPU
// ticks last seen kept across reads (readers come and go). GET /host and the events' `host` samples share it.
import type { Lang } from "../ops/i18n.ts";
import type { Seen } from "../read/host.ts";
import type { Readers } from "../read/pool.ts";
import { wall } from "../ops/fibers.ts";

export class Host {
  private readers: Readers;
  private cached: { at: number; info: any } | null = null;
  private seen: Seen = null;
  private reading: Promise<any> | null = null;

  constructor(readers: Readers) {
    this.readers = readers;
  }

  /// At most ten seconds old; one read at a time however many ask.
  sample(lang: Lang = "zh"): Promise<any> {
    if (this.cached !== null && wall.now() - this.cached.at < 10_000) return Promise.resolve(this.cached.info);
    this.reading ??= this.readers
      .read("host", { seen: this.seen }, lang)
      .then((text) => {
        const { info, seen } = JSON.parse(text);
        this.seen = seen;
        this.cached = { at: info.checkedAt, info };
        return info;
      })
      .finally(() => (this.reading = null));
    return this.reading;
  }
}
