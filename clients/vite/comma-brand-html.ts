import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import type { Plugin } from "vite";

const commaBrandIconPath = "brand/comma/icon.png";

interface CommaBrandHtmlOptions {
  channel: string;
  productName: string;
}

// The served icon is the favicon and the in-app logo, which renders at most
// 64 CSS px (the sign-in screen). Each channel file is 192 px, enough for a
// 3x display; a larger file only adds bytes to every page load.
function commaBrandIconFile(channel: string) {
  return fileURLToPath(
    new URL(`../assets/brand/comma/${channel}.png`, import.meta.url)
  );
}

export function commaBrandHtmlPlugin(options: CommaBrandHtmlOptions): Plugin {
  const iconFile = commaBrandIconFile(options.channel);

  return {
    name: "comma-brand-html",
    configureServer(server) {
      server.middlewares.use((request, response, next) => {
        if (!request.url) {
          next();
          return;
        }

        const { pathname } = new URL(request.url, "http://localhost");

        if (pathname !== `/${commaBrandIconPath}`) {
          next();
          return;
        }

        response.statusCode = 200;
        response.setHeader("Content-Type", "image/png");
        response.end(readFileSync(iconFile));
      });
    },
    buildStart() {
      this.addWatchFile(iconFile);
    },
    generateBundle() {
      this.emitFile({
        type: "asset",
        fileName: commaBrandIconPath,
        source: readFileSync(iconFile),
      });
    },
    transformIndexHtml(html) {
      return html.replaceAll("%COMMA_PRODUCT_NAME%", options.productName);
    },
  };
}
