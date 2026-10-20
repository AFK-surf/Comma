export function isClientCiPath(path: string): boolean;
export function isComputerUseCiPath(path: string): boolean;
export function computerUseCiChanged(paths: string[]): boolean;
export function electronCiChanged(paths: string[]): boolean;
export function synchCiChanged(paths: string[]): boolean;
export function androidCiChanged(paths: string[]): boolean;
export function appleCiChanged(paths: string[]): boolean;
export function clientCiChanged(paths: string[]): boolean;
export function clientBuildChanged(paths: string[]): boolean;
export function websiteChanged(paths: string[]): boolean;
export function storybookChanged(paths: string[]): boolean;
export function workflowCiChanged(paths: string[]): boolean;
export function gitChangedFiles(base: string, head: string, cwd: string): string[];
export function writeGitHubOutput(
  path: string,
  key: string,
  value: string
): Promise<void>;
export function validateClientGate(
  needs: Record<
    string,
    { result: string; outputs?: Record<string, string | undefined> }
  >,
  options?: {
    /** False for a pull request without the `full-e2e` label: its full E2E jobs skip. */
    fullE2e?: boolean;
  }
): string[];
