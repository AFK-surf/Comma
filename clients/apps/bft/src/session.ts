/**
 * Sign out the same way the LiveView shell does: a form POST to /logout with
 * the Phoenix method override and the page's CSRF token.
 */
export function signOut(doc: Document = document) {
  postForm(doc, "/logout", [["_method", "delete"]]);
}

/** Reopens the first-run setup from its first step. */
export function restartOnboarding(doc: Document = document) {
  postForm(doc, "/onboarding/restart", []);
}

function postForm(doc: Document, action: string, extra: [string, string][]) {
  const token =
    doc.querySelector('meta[name="csrf-token"]')?.getAttribute("content") ?? "";
  const form = doc.createElement("form");
  form.method = "post";
  form.action = action;
  const fields: [string, string][] = [...extra, ["_csrf_token", token]];
  for (const [name, value] of fields) {
    const input = doc.createElement("input");
    input.type = "hidden";
    input.name = name;
    input.value = value;
    form.appendChild(input);
  }
  doc.body.appendChild(form);
  form.submit();
}
