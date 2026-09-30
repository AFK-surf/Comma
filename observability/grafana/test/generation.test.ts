import { readFile, readdir, rm, writeFile } from "node:fs/promises";
import path from "node:path";

import { describe, expect, it } from "vitest";

import { environments } from "../src/environments.js";
import type { DashboardEnvironment } from "../src/environments.js";
import {
  generateManagedProjections,
  projectionErrors,
  renderDashboards,
} from "../src/generate.js";
import { renderTerraformAlertingProjection } from "../src/alerting/resources.js";
import { dashboardDefinitions } from "../src/inventory.js";
import type { DashboardJson } from "../src/validate.js";
import { validateInventory } from "../src/validate.js";

const packageRoot = path.resolve(import.meta.dirname, "..");
const dashboardsRoot = path.join(packageRoot, "dashboards");
const alertingProjectionPath = path.join(
  packageRoot,
  "terraform",
  "alerting-rules.json",
);

describe("deterministic generation", () => {
  it("generates the source inventory byte-identically without orphan JSON", async () => {
    const first = await readGeneratedFiles();
    expect(projectionErrors(renderDashboards(), first)).toEqual([]);
    const alertingProjectionBefore = await readFile(
      alertingProjectionPath,
      "utf8",
    );
    expect(alertingProjectionBefore).toBe(renderTerraformAlertingProjection());

    await generateManagedProjections();
    const second = await readGeneratedFiles();

    expect(second).toEqual(first);
    expect([...first.keys()]).toEqual(
      environments
        .flatMap((environment) => [
          `${environment.outputDirectory}/_folder.json`,
          ...dashboardDefinitions.map(
            (definition) =>
              `${environment.outputDirectory}/${definition.slug}.json`,
          ),
        ])
        .sort(),
    );
    for (const contents of first.values()) {
      expect(contents.endsWith("\n")).toBe(true);
      expect(contents).not.toMatch(/Users\/|generatedAt|buildNumber/);
      expect(() => JSON.parse(contents)).not.toThrow();
    }
    expect(await readFile(alertingProjectionPath, "utf8")).toBe(
      alertingProjectionBefore,
    );
  });

  it("fails closed for generated projection drift", () => {
    const expected = new Map([["staging/owned.json", '{"uid":"owned"}\n']]);
    const invalidCases = [
      {
        name: "missing generated file",
        actual: new Map<string, string>(),
        message: "missing generated dashboard staging/owned.json",
      },
      {
        name: "hand-edited generated file",
        actual: new Map([["staging/owned.json", '{"uid":"edited"}\n']]),
        message: "generated dashboard drift staging/owned.json",
      },
      {
        name: "orphan generated file",
        actual: new Map([
          ["staging/owned.json", '{"uid":"owned"}\n'],
          ["staging/orphan.json", "{}\n"],
        ]),
        message: "orphan generated dashboard staging/orphan.json",
      },
    ] as const;

    for (const invalidCase of invalidCases) {
      expect(
        projectionErrors(expected, invalidCase.actual).join("\n"),
        invalidCase.name,
      ).toContain(invalidCase.message);
    }
  });

  it("discovers an orphan JSON at the generated-tree root", async () => {
    const orphanPath = path.join(dashboardsRoot, "orphan.json");
    await writeFile(orphanPath, "{}\n", "utf8");
    try {
      expect(
        projectionErrors(renderDashboards(), await readGeneratedFiles()).join(
          "\n",
        ),
      ).toContain("orphan generated dashboard orphan.json");
    } finally {
      await rm(orphanPath, { force: true });
    }
  });

  it("builds valid, isolated dashboards with stable identities", async () => {
    const dashboards = environments.flatMap((environment) =>
      dashboardDefinitions.map((definition) => ({
        environment,
        filename: `${environment.outputDirectory}/${definition.slug}.json`,
        dashboard: definition.build(environment) as DashboardJson,
      })),
    );

    expect(validateInventory(dashboards)).toEqual([]);
    expect(dashboards.map(({ dashboard }) => dashboard.uid)).toEqual([
      "comma-staging-platform-overview",
      "comma-staging-telemetry-pipeline",
      "comma-staging-bft",
      "comma-staging-comma-product",
      "comma-staging-salix-runtime",
      "comma-staging-billing",
    ]);
    expect(JSON.stringify(dashboards)).not.toContain("production");
  });

  it("derives environment metadata instead of leaking staging labels", () => {
    const productionLike: DashboardEnvironment = {
      name: "production",
      datasourceUid: "example-prod-datasource",
      project: "example-prod-project",
      outputDirectory: "production",
      uidPrefix: "comma-production",
      folderUid: "comma-production",
      folderTitle: "production",
    };
    const serialized = JSON.stringify(
      dashboardDefinitions.map((definition) =>
        definition.build(productionLike),
      ),
    );

    expect(serialized).toContain("example-prod-datasource");
    expect(serialized).toContain("example-prod-project");
    expect(serialized).toContain("Production platform health");
    expect(serialized).toContain("production");
    expect(serialized).not.toContain("staging");
  });

  it("generates stable folder metadata from the environment source", () => {
    const folder = renderDashboards().get("staging/_folder.json");
    expect(folder).toBeDefined();
    expect(JSON.parse(folder ?? "{}")).toEqual({
      apiVersion: "folder.grafana.app/v1",
      kind: "Folder",
      metadata: { name: "comma-staging" },
      spec: { title: "staging" },
    });
  });
});

async function readGeneratedFiles(): Promise<Map<string, string>> {
  const files = new Map<string, string>();
  await visit(dashboardsRoot, "");
  return files;

  async function visit(
    directory: string,
    relativeDirectory: string,
  ): Promise<void> {
    for (const entry of (
      await readdir(directory, { withFileTypes: true })
    ).sort((a, b) => a.name.localeCompare(b.name))) {
      const relativePath = path.posix.join(relativeDirectory, entry.name);
      const absolutePath = path.join(directory, entry.name);
      if (entry.isDirectory()) {
        await visit(absolutePath, relativePath);
      } else if (entry.isFile() && entry.name.endsWith(".json")) {
        files.set(relativePath, await readFile(absolutePath, "utf8"));
      }
    }
  }
}
