import { z } from "zod";
import {
  DatasetItem,
  defineDatasetLoader,
  type LoadedDatasetItem,
} from "@evalens/core";

export const BasicDatasetItem = DatasetItem.extend({
  input: z.object({ answer: z.string() }).strict(),
  expected: z.object({ answer: z.string() }).strict(),
});
export type BasicDatasetItem = LoadedDatasetItem<typeof BasicDatasetItem>;

export const loadBasicDataset = defineDatasetLoader({
  name: "basic-dataset",
  digest: "39a64dfc9535ed0f22e12cf57448d086359e33baa0dec7ab27973fcffcccdc9f",
  itemSchema: BasicDatasetItem,
});
