import { readFile } from "node:fs/promises";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const clientPath = resolve(
  root,
  "clients/packages/recommendation-contract/catalog/recommendation-template-catalog.v1.json",
);
const agentPath = resolve(
  root,
  "resources/salix-system-files/recommendation-template-catalog.v1.json",
);

const [clientCatalog, agentCatalog] = await Promise.all([
  readFile(clientPath, "utf8").then(JSON.parse),
  readFile(agentPath, "utf8").then(JSON.parse),
]);

if (JSON.stringify(clientCatalog) !== JSON.stringify(agentCatalog)) {
  throw new Error(
    "Recommendation template catalog drift: update the client and agent copies together.",
  );
}

if (
  clientCatalog.catalogVersion !== 1 ||
  clientCatalog.templates.length !== 2
) {
  throw new Error(
    "Recommendation template catalog v1 has an unexpected shape.",
  );
}

const templatesById = new Map(
  clientCatalog.templates.map((template) => [template.template, template]),
);

if (
  templatesById.get("text-list@1")?.itemFields?.action !== "required" ||
  templatesById.get("media-list@1")?.itemFields?.action !== "required"
) {
  throw new Error(
    "Recommendation text and media rows must both declare a required action.",
  );
}

if (
  !clientCatalog.snapshot?.fields?.summary?.startsWith(
    "required:non-empty-array-of-document-parts;",
  ) ||
  !clientCatalog.snapshot.fields.summary.includes("greeting-only title") ||
  !clientCatalog.snapshot.fields.summary.includes(
    "paragraph break is a blank line",
  ) ||
  !clientCatalog.snapshot.fields.summary.includes("inline-link") ||
  clientCatalog.limits?.summaryTitleCharacters !== 48 ||
  clientCatalog.snapshot?.warningFields?.code === undefined ||
  clientCatalog.snapshot?.warningFields?.message === undefined
) {
  throw new Error(
    "Recommendation template catalog must disclose the root summary and warning contracts.",
  );
}

console.log("Recommendation template catalog copies are aligned.");
