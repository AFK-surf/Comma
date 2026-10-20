export const viteIsServer: string;
export function hostCache(): string | undefined;
export function ensureCompiled(given?: {
  isServer?: string;
  directory?: string;
  cache?: string | undefined;
  compile?: (job: { project: string; outdir: string }) => Promise<unknown>;
}): Promise<"current" | "restored" | "compiled">;
