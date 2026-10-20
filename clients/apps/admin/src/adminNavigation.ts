export type AdminSection =
  | "overview"
  | "users"
  | "oauth"
  | "compute"
  | "billing"
  | "free-models"
  | "guest"
  | "audit";

const defaultAdminSection: AdminSection = "users";
const sectionParam = "section";
// View-scoped parameters belong to the section that wrote them.
const viewParams = ["tenant", "registration", "user"];

export function adminSectionFromSearch(search: string): AdminSection {
  const section = new URLSearchParams(search).get(sectionParam);
  return section === "overview" ||
    section === "oauth" ||
    section === "compute" ||
    section === "billing" ||
    section === "free-models" ||
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
