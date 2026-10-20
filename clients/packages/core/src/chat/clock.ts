// Chat's world from the core: its runner (timers sleep on the core's Clock, a TestClock in tests), the time the
// Clock's, random numbers the host's bytes. Nothing here reads the wall clock or calls setTimeout.
import type { Ctx } from "../ctx.ts";
import { type ChatEnv, uuidOf } from "./env.ts";

export function coreChatEnv(ctx: Ctx): ChatEnv {
  const bytes = (n: number) => {
    const buf = new Uint8Array(n);
    ctx.host.randomBytes(buf);
    return buf;
  };
  return {
    runner: ctx.runner,
    now: () => ctx.now(),
    random() {
      const b = bytes(4);
      return (((b[0]! << 24) >>> 0) + (b[1]! << 16) + (b[2]! << 8) + b[3]!) / 2 ** 32;
    },
    uuid: () => uuidOf(bytes(16)),
  };
}
