const ID_PATTERN = /^[a-zA-Z0-9][a-zA-Z0-9_-]{0,127}$/;

export function parseSandboxId(value: string | undefined): string | undefined {
  if (!value || !ID_PATTERN.test(value)) return undefined;
  return value;
}

export function sandboxIdFromPath(
  pathname: string,
): { id: string; suffix: string } | undefined {
  const prefix = "/internal/v1/sandboxes/";
  if (!pathname.startsWith(prefix)) return undefined;
  const rest = pathname.slice(prefix.length);
  const [rawId = "", ...tail] = rest.split("/");
  const id = parseSandboxId(rawId);
  if (!id) return undefined;
  return { id, suffix: `/${tail.join("/")}` };
}
