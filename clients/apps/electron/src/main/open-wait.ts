// LaunchServices can observe a short-lived app after it has already exited.
// This only identifies that wait race; callers must still validate app output.
export function openWaitTargetAlreadyExited(result: unknown): boolean {
  if (typeof result !== "object" || result === null) return false;
  const { code, stderr } = result as { code?: unknown; stderr?: unknown };
  return (
    code === 1 &&
    typeof stderr === "string" &&
    stderr.trim() ===
      "Unable to block on applications (initial call to kevent() failed: No such process)"
  );
}
