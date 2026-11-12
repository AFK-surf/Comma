import { describe, expect, it } from "vitest";
import { z } from "zod";
import { lazySchema } from "../lazy-schema.ts";

describe("a schema made on first use", () => {
  it("is not made until something reads it, then made once", () => {
    let made = 0;
    const id = lazySchema(() => {
      made += 1;
      return z.string().min(1);
    });
    expect(made).toBe(0);
    expect(id.safeParse("a").success).toBe(true);
    expect(id.safeParse("").success).toBe(false);
    expect(made).toBe(1);
  });

  it("parses inside another schema, extends, and is the kind of schema it stands for", () => {
    const item = lazySchema(() => z.object({ id: z.string() }));
    const list = z.object({ items: z.array(item) });
    expect(list.parse({ items: [{ id: "a", extra: 1 }] })).toEqual({
      items: [{ id: "a" }],
    });
    expect(() => list.parse({ items: [{}] })).toThrow();
    expect(item.extend({ n: z.number() }).parse({ id: "a", n: 1 })).toEqual({
      id: "a",
      n: 1,
    });
    expect(item).toBeInstanceOf(z.ZodObject);
  });
});
