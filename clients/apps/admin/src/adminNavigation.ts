export type AdminSection =
  | "users"
  | "oauth"
  | "compute"
  | "billing"
  | "models"
  | "guest"
  | "audit";

const defaultAdminSection: AdminSection = "users";
const sectionParam = "section";
// View-scoped parameters belong to the section that wrote them.
const viewParams = ["tenant", "registration"];

export function adminSectionFromSearch(search: string): AdminSection {
  const section = new URLSearchParams(search).get(sectionParam);
  return section === "oauth" ||
    section === "compute" ||
    section === "billing" ||
    section === "models" ||
    section === "guest" ||
    section === "audit"
    ? section
    : defaultAdminSection;
}

export function adminSectionHref(section: AdminSection, currentHref: string): string {
  const url = new URL(currentHref);
  for (const param of viewParams) url.searchParams.delete(param);
  if (section === defaultAdminSection) {
    url.searchParams.delete(sectionParam);
  } else {
    url.searchParams.set(sectionParam, section);
  }
  return `${url.pathname}${url.search}${url.hash}`;
}

export function replaceAdminViewParams(params: Record<string, string | undefined>) {
  const url = new URL(window.location.href);
  for (const [name, value] of Object.entries(params)) {
    if (value) {
      url.searchParams.set(name, value);
    } else {
      url.searchParams.delete(name);
    }
  }
  if (url.href !== window.location.href) {
    window.history.replaceState(window.history.state, "", url);
  }
}
