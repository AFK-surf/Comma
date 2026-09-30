export function foundationCheckId(name) {
  return name
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
}

export function formatFoundationCheckList(results) {
  return results.map((result) => ({
    ...(result.error ? { error: result.error } : {}),
    id: result.id,
    name: result.name,
    status: result.status,
  }));
}

export function findNativeSessionAdmissionViolations(capabilities) {
  const validAdmissions = new Set(["lifecycle", "required", "local_only"]);
  const violations = [];

  for (const capability of capabilities) {
    if (!validAdmissions.has(capability.sessionAdmission)) {
      violations.push(
        `${capability.id} has invalid sessionAdmission ${String(
          capability.sessionAdmission
        )}`
      );
      continue;
    }

    const rationale = capability.sessionAdmissionRationale?.trim();
    if (capability.sessionAdmission === "local_only" && !rationale) {
      violations.push(`${capability.id} local_only is missing a rationale`);
    }
    if (capability.sessionAdmission !== "local_only" && rationale) {
      violations.push(
        `${capability.id} declares a local-only rationale with ${capability.sessionAdmission}`
      );
    }
  }

  return violations;
}
