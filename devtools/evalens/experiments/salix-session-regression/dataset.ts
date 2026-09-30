import type { DatasetSource, LoadedDatasetItem } from "@evalens/core";
import { SalixDatasetItem } from "@evalens/cli/salix-dataset-item";

export const SalixSessionRegressionItem = SalixDatasetItem;

export type SalixSessionRegressionItem = LoadedDatasetItem<
  typeof SalixSessionRegressionItem
>;

export async function loadSalixSessionRegressionDataset(
  source: DatasetSource | undefined,
  params: { datasetName: string; datasetDigest: string }
) {
  if (!source) throw new Error("dataset source is required");
  return source.load({
    name: params.datasetName,
    digest: params.datasetDigest,
    itemSchema: SalixSessionRegressionItem,
  });
}
