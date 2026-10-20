import { fileURLToPath } from "node:url";
import { createElement, type ComponentType } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { runnerImport, type Plugin } from "vite";

const virtualModuleId = "virtual:comma-logo-animation-markup";
const resolvedVirtualModuleId = `\0${virtualModuleId}`;
const componentFile = fileURLToPath(
  new URL(
    "../packages/ui/src/components/comma-mascot/CommaLogoAnimation.tsx",
    import.meta.url
  )
);

type CommaLogoAnimationModule = {
  CommaLogoAnimation: ComponentType<{
    "aria-hidden": boolean;
    cutout: boolean;
    height: string;
    style: { color: string };
    width: string;
  }>;
};

// A first paint that runs before the application loads React shows the logo
// animation as markup. Render the real component at build time so that both
// stay one design. The cutout aperture shows whatever surface is behind it, and
// the mark fills the element that sizes it.
export function commaLogoAnimationMarkupPlugin(): Plugin {
  return {
    name: "comma-logo-animation-markup",
    resolveId(id) {
      return id === virtualModuleId ? resolvedVirtualModuleId : undefined;
    },
    async load(id) {
      if (id !== resolvedVirtualModuleId) return undefined;
      this.addWatchFile(componentFile);
      const { module } = await runnerImport<CommaLogoAnimationModule>(componentFile, {
        configFile: false,
        logLevel: "error",
      });
      const markup = renderToStaticMarkup(
        createElement(module.CommaLogoAnimation, {
          "aria-hidden": true,
          cutout: true,
          height: "100%",
          style: { color: "inherit" },
          width: "100%",
        })
      );
      return `export default ${JSON.stringify(markup)};`;
    },
  };
}
