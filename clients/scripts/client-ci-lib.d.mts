export function isClientCiPath(path: string): boolean;
export function isComputerUseCiPath(path: string): boolean;
export function computerUseCiChanged(paths: string[]): boolean;
export function clientCiChanged(paths: string[]): boolean;
export function clientBuildChanged(paths: string[]): boolean;
export function websiteChanged(paths: string[]): boolean;
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
  >
): string[];
