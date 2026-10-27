/// <reference types="vitest/config" />
import { defineConfig, type Plugin } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import { fileURLToPath } from "node:url";

/**
 * Puts the whole app into `dist/index.html`: one inline module script and
 * inline styles. Comma runs an app in a sandbox without network, from one
 * module script, so the build must not split code into chunks.
 */
function singleFile(): Plugin {
  return {
    name: "comma-single-file",
    enforce: "post",
    generateBundle(_options, bundle) {
      const html = Object.values(bundle).find(
        (file) => file.type === "asset" && file.fileName === "index.html"
      );
      if (!html || html.type !== "asset") return;
      let source = String(html.source);
      for (const [name, file] of Object.entries(bundle)) {
        if (file.type === "chunk" && file.isEntry) {
          const tag = new RegExp(
            `<script[^>]*src="[./]*${escape(name)}"[^>]*></script>`
          );
          if (!tag.test(source)) continue;
          // An inline script ends at the first `</script`.
          const code = file.code.replaceAll("</script", "<\\/script");
          source = source.replace(tag, () => `<script type="module">${code}</script>`);
          delete bundle[name];
        } else if (file.type === "asset" && name.endsWith(".css")) {
          const tag = new RegExp(`<link[^>]*href="[./]*${escape(name)}"[^>]*>`);
          if (!tag.test(source)) continue;
          source = source.replace(tag, () => `<style>${String(file.source)}</style>`);
          delete bundle[name];
        }
      }
      html.source = source;
    },
  };
}

const escape = (text: string) => text.replaceAll(/[.*+?^${}()|[\]\\]/g, "\\$&");

export default defineConfig({
  plugins: [react(), tailwindcss(), singleFile()],
  resolve: {
    alias: { "@": fileURLToPath(new URL("./src", import.meta.url)) },
  },
  base: "./",
  build: {
    outDir: "dist",
    emptyOutDir: true,
    // Images and fonts become data: URLs inside the bundle.
    assetsInlineLimit: () => true,
    cssCodeSplit: false,
    modulePreload: false,
    rolldownOptions: { output: { codeSplitting: false } },
  },
  test: {
    environment: "jsdom",
  },
});
