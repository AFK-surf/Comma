import { defineConfig } from "drizzle-kit";

export default defineConfig({
  dialect: "sqlite",
  schema: "./packages/store/src/metadata/schema.ts",
  out: "./packages/store/src/metadata/migrations",
});
