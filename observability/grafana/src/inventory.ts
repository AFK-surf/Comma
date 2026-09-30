import type { DashboardEnvironment } from "./environments.js";
import { buildBft, bftSlug } from "./dashboards/bft.js";
import { buildBilling, billingSlug } from "./dashboards/billing.js";
import { buildCommaProduct, commaProductSlug } from "./dashboards/comma-product.js";
import {
  buildPlatformOverview,
  platformOverviewSlug,
} from "./dashboards/platform-overview.js";
import {
  buildSalixRuntime,
  salixRuntimeSlug,
} from "./dashboards/salix-runtime.js";
import {
  buildTelemetryPipeline,
  telemetryPipelineSlug,
} from "./dashboards/telemetry-pipeline.js";

export interface DashboardDefinition {
  readonly slug: string;
  readonly build: (environment: DashboardEnvironment) => unknown;
}

export const dashboardDefinitions: readonly DashboardDefinition[] = [
  { slug: platformOverviewSlug, build: buildPlatformOverview },
  { slug: telemetryPipelineSlug, build: buildTelemetryPipeline },
  { slug: bftSlug, build: buildBft },
  { slug: commaProductSlug, build: buildCommaProduct },
  { slug: salixRuntimeSlug, build: buildSalixRuntime },
  { slug: billingSlug, build: buildBilling },
];
