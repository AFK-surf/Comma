// The core worker's iroh (vite.config.ts `commaMeshModule`): its browser build, loaded.
declare module "virtual:comma-mesh" {
  import type { WebMesh } from "@comma/core/web";

  export function load(): Promise<WebMesh>;
}
