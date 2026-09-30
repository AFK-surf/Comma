import type { z } from "zod";

export function renderCardContract(
  schemas: Record<string, z.ZodType>,
  frame: Record<string, z.ZodType>
): string;
