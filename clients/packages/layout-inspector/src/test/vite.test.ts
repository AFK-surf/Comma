import { describe, expect, it } from "vitest";
import { layoutInspectorSourcePlugin } from "../vite";

describe("layout inspector Vite source plugin", () => {
  it("injects source locations into native JSX elements only", async () => {
    const plugin = layoutInspectorSourcePlugin({
      enabled: true,
      root: "/repo",
    });
    const transform = plugin.transform;
    if (typeof transform !== "function") {
      throw new TypeError("Expected a callable Vite transform hook.");
    }
    const runTransform = transform as unknown as (
      code: string,
      id: string
    ) => Promise<{ code: string } | null>;

    const result = await runTransform(
      [
        "const Card = () => <article />;",
        "export function Example() {",
        "  return (",
        "    <section>",
        "      <Card />",
        '      <div className="target" />',
        "    </section>",
        "  );",
        "}",
      ].join("\n"),
      "/repo/clients/packages/ui/src/Example.tsx"
    );
    const code = result?.code;

    expect(code).toContain(
      'data-comma-source="clients/packages/ui/src/Example.tsx:1:20"'
    );
    expect(code).toContain(
      'data-comma-source="clients/packages/ui/src/Example.tsx:4:5"'
    );
    expect(code).toContain(
      'data-comma-source="clients/packages/ui/src/Example.tsx:6:7"'
    );
    expect(code).not.toMatch(/<Card[^>]*data-comma-source/);
  });

  it("preserves an explicitly supplied source location", async () => {
    const plugin = layoutInspectorSourcePlugin({
      enabled: true,
      root: "/repo",
    });
    const transform = plugin.transform;
    if (typeof transform !== "function") {
      throw new TypeError("Expected a callable Vite transform hook.");
    }
    const runTransform = transform as unknown as (
      code: string,
      id: string
    ) => Promise<{ code: string } | null>;

    const result = await runTransform(
      'export const Example = () => <div data-comma-source="manual.tsx:1:1" />;',
      "/repo/Example.tsx"
    );

    expect(result).toBeNull();
  });
});
