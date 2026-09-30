export type ExternalProvider = "github" | "linear" | "notion" | "google" | "slack";

/**
 * Provider observations are deliberately read-only snapshots. Missing resources are
 * represented as `exists: false`; authentication, authorization, transport, and
 * malformed-response failures are thrown so the experiment can classify them as
 * infrastructure errors rather than scored Agent failures.
 */
export type ExternalResourceObservation<Resource> = {
  provider: ExternalProvider;
  resourceType: string;
  lookup: string;
  exists: boolean;
  observedAt: string;
  resource?: Resource;
};

export interface ExternalResourceObserver<Target, Observation> {
  readonly provider: ExternalProvider;
  observe(target: Target): Promise<Observation>;
}

export function createExternalObservation<Resource>(input: {
  provider: ExternalProvider;
  resourceType: string;
  lookup: string;
  resource?: Resource;
  now: () => Date;
}): ExternalResourceObservation<Resource> {
  return {
    provider: input.provider,
    resourceType: input.resourceType,
    lookup: input.lookup,
    exists: input.resource !== undefined,
    observedAt: input.now().toISOString(),
    ...(input.resource === undefined ? {} : { resource: input.resource }),
  };
}
