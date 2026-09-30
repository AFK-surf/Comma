import type { DatasetItem } from "../dataset";

export type ItemDigest = {
  itemId: string;
  itemDigest: string;
};

export function canonicalJson(value: unknown): string {
  if (value === null || typeof value === "string" || typeof value === "boolean") {
    return JSON.stringify(value);
  }
  if (typeof value === "number") {
    if (!Number.isFinite(value))
      throw new Error("canonical JSON numbers must be finite");
    return JSON.stringify(value);
  }
  if (Array.isArray(value)) {
    return `[${value.map((entry) => canonicalJson(entry)).join(",")}]`;
  }
  if (typeof value === "object") {
    const record = value as Record<string, unknown>;
    return `{${Object.keys(record)
      .sort(compareStrings)
      .map((key) => `${JSON.stringify(key)}:${canonicalJson(record[key])}`)
      .join(",")}}`;
  }
  throw new Error(`value is not JSON-safe: ${typeof value}`);
}

export function digestCanonicalJson(value: unknown): string {
  return new Bun.CryptoHasher("sha256").update(canonicalJson(value)).digest("hex");
}

export function digestDatasetItem(item: DatasetItem<unknown, unknown>): string {
  const { archive: _archive, ...persistedItem } = item;
  return digestCanonicalJson(persistedItem);
}

export function digestDataset(items: readonly ItemDigest[]): string {
  const sortedItems = [...items].sort((left, right) =>
    compareStrings(left.itemId, right.itemId)
  );
  return digestCanonicalJson(sortedItems);
}

export function digestDatasetSelection(
  datasetDigest: string,
  itemIds: readonly string[]
): string {
  return digestCanonicalJson({
    datasetDigest,
    itemIds: [...itemIds].sort(compareStrings),
  });
}

function compareStrings(left: string, right: string): number {
  if (left < right) return -1;
  if (left > right) return 1;
  return 0;
}
