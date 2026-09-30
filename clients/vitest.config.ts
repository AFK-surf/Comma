import { resolve } from "node:path";
import type { UserConfig } from "vite";
import { defineConfig } from "vitest/config";

type OxcConfig = Exclude<UserConfig["oxc"], false | undefined>;

const testTransform = {
  resolve: {
    alias: {
      "@comma/app/host-runtime": resolve(
        import.meta.dirname,
        "packages/app/src/runtime-chat/CommaAppRuntime.ts"
      ),
      "@comma/app/chat-coordinator": resolve(
        import.meta.dirname,
        "packages/app/src/runtime-chat/coordinator/ChatCoordinator.ts"
      ),
      "@comma/app/api": resolve(import.meta.dirname, "packages/app/src/api/index.ts"),
      "@comma/app/auth": resolve(import.meta.dirname, "packages/app/src/auth/index.ts"),
      "@comma/app/chat-core": resolve(
        import.meta.dirname,
        "packages/app/src/chat-core.ts"
      ),
      "@comma/app/chat-runtime": resolve(
        import.meta.dirname,
        "packages/app/src/chat-runtime.ts"
      ),
      "@comma/app": resolve(import.meta.dirname, "packages/app/src/index.tsx"),
      "@comma/chat-contract/dynamic-ui-runtime": resolve(
        import.meta.dirname,
        "packages/chat-contract/src/dynamic-ui/runtime.ts"
      ),
      "@comma/chat-contract/dynamic-ui-cards": resolve(
        import.meta.dirname,
        "packages/chat-contract/src/dynamic-ui/cardsEntry.ts"
      ),
      "@comma/chat-contract/dynamic-ui-card-fixtures": resolve(
        import.meta.dirname,
        "packages/chat-contract/src/dynamic-ui/cardFixtures.ts"
      ),
      "@comma/chat-contract": resolve(
        import.meta.dirname,
        "packages/chat-contract/src/index.ts"
      ),
      "@comma/config": resolve(import.meta.dirname, "packages/config/src/index.ts"),
      "@comma/i18n/react": resolve(import.meta.dirname, "packages/i18n/src/react.tsx"),
      "@comma/i18n/vite": resolve(import.meta.dirname, "packages/i18n/src/vite.ts"),
      "@comma/i18n": resolve(import.meta.dirname, "packages/i18n/src/index.ts"),
      "@comma/layout-inspector": resolve(
        import.meta.dirname,
        "packages/layout-inspector/src/index.ts"
      ),
      "@comma/native-bridge": resolve(
        import.meta.dirname,
        "packages/native-bridge/src/index.ts"
      ),
      "@comma/native-bridge/web": resolve(
        import.meta.dirname,
        "packages/native-bridge/src/web.ts"
      ),
      "@comma/session-contract": resolve(
        import.meta.dirname,
        "packages/session-contract/src/index.ts"
      ),
      "@comma/test-utils": resolve(import.meta.dirname, "packages/test-utils/src"),
      "@comma/ui": resolve(import.meta.dirname, "packages/ui/src/index.ts"),
    },
  },
  oxc: {
    tsconfig: {
      compilerOptions: {
        jsx: "react-jsx",
        jsxImportSource: "react",
        target: "ES2024",
        useDefineForClassFields: true,
      },
    },
  } as unknown as OxcConfig,
} satisfies UserConfig;
const testExclude = ["**/node_modules/**", "**/dist/**", "**/out/**", "**/.vite/**"];

export default defineConfig({
  ...testTransform,
  test: {
    clearMocks: true,
    restoreMocks: true,
    coverage: {
      provider: "v8",
      reporter: ["text", "lcov"],
    },
    projects: [
      {
        ...testTransform,
        test: {
          name: "node",
          environment: "node",
          include: ["{apps,packages}/**/test/**/*.test.ts", "scripts/**/*.test.ts"],
          exclude: testExclude,
        },
      },
      {
        ...testTransform,
        test: {
          name: "jsdom",
          environment: "jsdom",
          include: ["{apps,packages}/**/test/**/*.test.tsx"],
          setupFiles: ["./packages/test-utils/src/setup-dom.ts"],
          exclude: testExclude,
        },
      },
    ],
  },
});
