import tailwindcss from "@tailwindcss/vite";
import { paraglideVitePlugin } from "@inlang/paraglide-js";
import { tanstackRouter } from "@tanstack/router-plugin/vite";
import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

export default defineConfig({
  root: import.meta.dirname,
  plugins: [
    paraglideVitePlugin({
      project: new URL("./project.inlang", import.meta.url).pathname,
      outdir: new URL("./src/paraglide", import.meta.url).pathname,
      strategy: ["globalVariable", "baseLocale"],
    }),
    tanstackRouter({
      target: "react",
      routesDirectory: "./src/routes",
      generatedRouteTree: "./src/routeTree.gen.ts",
    }),
    tailwindcss(),
    react(),
  ],
  build: {
    outDir: "dist",
    emptyOutDir: true,
  },
});
