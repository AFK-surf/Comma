/**
 * Sign out the same way the LiveView shell does: a form POST to /logout with
 * the Phoenix method override and the page's CSRF token.
 */
export function signOut(doc: Document = document) {
  const token =
    doc.querySelector('meta[name="csrf-token"]')?.getAttribute("content") ?? "";
  const form = doc.createElement("form");
  form.method = "post";
  form.action = "/logout";
  const fields: [string, string][] = [
    ["_method", "delete"],
    ["_csrf_token", token],
  ];
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
