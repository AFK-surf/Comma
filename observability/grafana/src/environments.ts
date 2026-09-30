export type EnvironmentName = "staging" | "production";

// Live provider names are not stored in this repository. Generated dashboards
// reference these two hidden dashboard variables, which Grafana resolves at view
// time to the installed Cloud Monitoring datasource and its default project.
export const datasourceVariableName = "gcm_datasource";
export const projectVariableName = "gcp_project";

export interface DashboardEnvironment {
  readonly name: EnvironmentName;
  readonly datasourceUid: string;
  readonly project: string;
  readonly outputDirectory: string;
  readonly uidPrefix: string;
  readonly folderUid: string;
  readonly folderTitle: string;
}

export const environments: readonly DashboardEnvironment[] = [
  {
    name: "staging",
    datasourceUid: `\${${datasourceVariableName}}`,
    project: `\${${projectVariableName}}`,
    outputDirectory: "staging",
    uidPrefix: "comma-staging",
    folderUid: "comma-staging",
    folderTitle: "staging",
  },
];
