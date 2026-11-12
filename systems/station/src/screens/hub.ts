// A screen that cannot be opened now, as still.fail's station/src/screens/hub.ts says it.
import { tr } from "../ops/i18n.ts";

/// A source that cannot be opened now, and why, in words a person reads (`key` of the station's i18n catalog).
export class ScreenRefused extends Error {
  readonly status: number;
  readonly key: string;
  readonly args: Record<string, unknown>;
  constructor(status: number, key: string, args: Record<string, unknown> = {}) {
    super(tr("en", key, args));
    this.status = status;
    this.key = key;
    this.args = args;
  }
}
