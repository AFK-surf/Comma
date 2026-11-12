import type { z } from "zod";

export function renderCardContract(
  schemas: Record<string, z.ZodType>,
  frame: Record<string, z.ZodType>,
  levels: {
    level: number;
    base: number;
    kinds: Record<string, number>;
    features: Record<string, number>;
  }
): string;
