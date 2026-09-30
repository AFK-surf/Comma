import { mkdir, rm, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import path from "node:path";

import { renderTerraformAlertingProjection } from "./alerting/resources.js";
import { environments } from "./environments.js";
import { dashboardDefinitions } from "./inventory.js";

const packageRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
);
const dashboardsRoot = path.join(packageRoot, "dashboards");
const alertingProjectionPath = path.join(
  packageRoot,
  "terraform",
  "alerting-rules.json",
);

export async function generateManagedProjections(): Promise<void> {
  await rm(dashboardsRoot, { recursive: true, force: true });
  await mkdir(dashboardsRoot, { recursive: true });

  const rendered = renderDashboards();
  for (const [relativePath, output] of rendered) {
    const outputPath = path.join(dashboardsRoot, relativePath);
    await mkdir(path.dirname(outputPath), { recursive: true });
    await writeFile(outputPath, output, "utf8");
  }

  await mkdir(path.dirname(alertingProjectionPath), { recursive: true });
  await writeFile(
    alertingProjectionPath,
    renderTerraformAlertingProjection(),
    "utf8",
  );
}

export function renderDashboards(): ReadonlyMap<string, string> {
  const rendered = new Map<string, string>();
  for (const environment of environments) {
    rendered.set(
      `${environment.outputDirectory}/_folder.json`,
      `${JSON.stringify(
        {
          apiVersion: "folder.grafana.app/v1",
          kind: "Folder",
          metadata: { name: environment.folderUid },
          spec: { title: environment.folderTitle },
        },
        null,
        2,
      )}\n`,
    );
    for (const definition of dashboardDefinitions) {
      const relativePath = `${environment.outputDirectory}/${definition.slug}.json`;
      rendered.set(
        relativePath,
        `${JSON.stringify(definition.build(environment), null, 2)}\n`,
      );
    }
  }
  return rendered;
}

export function projectionErrors(
  expected: ReadonlyMap<string, string>,
  actual: ReadonlyMap<string, string>,
): readonly string[] {
  const errors: string[] = [];
  for (const [filename, contents] of expected) {
    const actualContents = actual.get(filename);
    if (actualContents === undefined) {
      errors.push(`missing generated dashboard ${filename}`);
    } else if (actualContents !== contents) {
      errors.push(`generated dashboard drift ${filename}`);
    }
  }
  for (const filename of actual.keys()) {
    if (!expected.has(filename)) {
      errors.push(`orphan generated dashboard ${filename}`);
    }
  }
  return errors;
}

if (
  process.argv[1] !== undefined &&
  path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)
) {
  await generateManagedProjections();
}
