import type { Archive } from "bun";
import { z } from "zod";

import { ItemId } from "./schemas";

/**
 * Access to one dataset item's attachment archive. Implementations must defer
 * reading archive bytes until one of these methods is called.
 */
export type DatasetItemArchive = Pick<Archive, "blob" | "bytes" | "extract" | "files">;

export const DatasetItem = z.object({
  id: ItemId,
  input: z.json(),
  expected: z.json(),
});

export type DatasetItem<Input, Expected> = {
  id: string;
  input: Input;
  expected: Expected;
  archive?: DatasetItemArchive;
};

export type Dataset<Item extends DatasetItem<unknown, unknown>> = {
  name: string;
  description?: string;
  digest?: string;
  items: Item[];
};

export type DatasetItemSchema = z.ZodType<
  Omit<DatasetItem<unknown, unknown>, "archive">,
  unknown
>;

export type LoadedDatasetItem<Schema extends DatasetItemSchema> = z.output<Schema> & {
  archive?: DatasetItemArchive;
};

export type DatasetReference<Schema extends DatasetItemSchema> = {
  name: string;
  digest: string;
  itemSchema: Schema;
};

export interface DatasetSource {
  load<Schema extends DatasetItemSchema>(
    reference: DatasetReference<Schema>
  ): Promise<Dataset<LoadedDatasetItem<Schema>>>;
}

export function defineDatasetLoader<Schema extends DatasetItemSchema>(
  reference: DatasetReference<Schema>
): (source?: DatasetSource) => Promise<Dataset<LoadedDatasetItem<Schema>>> {
  return (source) => {
    if (!source) {
      throw new Error(
        `dataset source is required to load ${reference.name}@${reference.digest}`
      );
    }
    return source.load(reference);
  };
}
