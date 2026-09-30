export type FoundationCheckStatus = "pass" | "fail";

export interface FoundationCheckResult {
  id: string;
  name: string;
  status: FoundationCheckStatus;
  error?: string | undefined;
}

export function foundationCheckId(name: string): string;

export function formatFoundationCheckList(
  results: readonly FoundationCheckResult[]
): FoundationCheckResult[];

export function findNativeSessionAdmissionViolations(
  capabilities: ReadonlyArray<{
    id: string;
    sessionAdmission?: string | undefined;
    sessionAdmissionRationale?: string | undefined;
  }>
): string[];
