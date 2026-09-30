import { isAdminAccessDenied, isAdminSessionRejection } from "./adminApi";

export async function guardedAdminCommand<T>(
  command: Promise<T>,
  onAccessDenied: () => void
): Promise<T> {
  try {
    return await command;
  } catch (error) {
    if (isAdminAccessDenied(error)) {
      onAccessDenied();
    }
    if (isAdminSessionRejection(error)) {
      throw new Error("The signed-in Session changed. Re-authentication is required.", {
        cause: error,
      });
    }
    throw error;
  }
}

export function adminErrorMessage(error: unknown, fallback: string) {
  return error instanceof Error && error.message ? error.message : fallback;
}
