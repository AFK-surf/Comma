import { resolve } from "node:path";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import localGroupSelectors from "../../vite/comma-tailwind";
import { getCommaConfig, parseCommaChannelStrict } from "@comma/config";
import { defineConfig } from "vite";
import { commaBrandHtmlPlugin } from "../../vite/comma-brand-html";

export function resolveAdminBuildConfiguration(environment: {
  COMMA_API_BASE_URL?: string;
  COMMA_BUILD_FLAVOR?: string;
  COMMA_SELFHOST_BUILD?: string;
}) {
  const commaBuildFlavor = normalizeCommaBuildFlavorStrict(
    environment.COMMA_BUILD_FLAVOR
  );
  const commaConfig = getCommaConfig(commaBuildFlavor);
  const explicitApiBaseUrl = environment.COMMA_API_BASE_URL?.trim();

  if (
    explicitApiBaseUrl &&
    commaBuildFlavor !== "dev" &&
    environment.COMMA_SELFHOST_BUILD !== "true"
  ) {
    throw new Error(
      "COMMA_API_BASE_URL is only supported for dev Admin builds. Staging and production use their channel-owned API origins."
    );
  }

  return {
    apiBaseUrl: explicitApiBaseUrl || commaConfig.apiBaseUrl,
    commaBuildFlavor,
    commaConfig,
  };
}

function normalizeCommaBuildFlavorStrict(value: string | undefined) {
  if (!value) {
    throw new Error(
      "Missing COMMA_BUILD_FLAVOR. Use an Admin build or deploy script that selects dev, staging, or prod."
    );
  }

  return parseCommaChannelStrict(value);
}

export function createAdminViteConfig(environment: {
  COMMA_API_BASE_URL?: string;
  COMMA_BUILD_FLAVOR?: string;
  COMMA_SELFHOST_BUILD?: string;
}) {
  const { apiBaseUrl, commaBuildFlavor, commaConfig } =
    resolveAdminBuildConfiguration(environment);

  return {
    define: {
      COMMA_DEFINED_BUILD_FLAVOR: JSON.stringify(commaBuildFlavor),
      COMMA_DEFINED_API_BASE_URL: JSON.stringify(apiBaseUrl),
    },
    resolve: {
      alias: {
        "@comma/app/auth/styles.css": resolve("../../packages/app/src/auth/styles.css"),
        "@comma/app/auth": resolve("../../packages/app/src/auth/index.ts"),
        "@comma/config": resolve("../../packages/config/src/index.ts"),
        "@comma/native-bridge": resolve("../../packages/native-bridge/src/index.ts"),
        "@comma/session-contract": resolve(
          "../../packages/session-contract/src/index.ts"
        ),
        "@comma/ui/styles.css": resolve("../../packages/ui/src/styles.css"),
        "@comma/ui": resolve("../../packages/ui/src/index.ts"),
      },
    },
    plugins: [
      commaBrandHtmlPlugin({
        channel: commaBuildFlavor,
        productName: `${commaConfig.productName} Admin`,
      }),
      react(),
      tailwindcss(),
      localGroupSelectors(),
    ],
    build: {
      rolldownOptions: {
        tsconfig: resolve("tsconfig.app.json"),
      },
    },
    optimizeDeps: {
      rolldownOptions: {},
    },
  };
}

export default defineConfig(() => createAdminViteConfig(process.env));
