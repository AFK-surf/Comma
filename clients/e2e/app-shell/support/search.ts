/**
 * The query a fixture was mounted with: set by the browser-project mount, or
 * the page URL's when a Playwright spec loads the fixture's own page.
 */
export const fixtureSearch = () =>
  (globalThis as { commaFixtureSearch?: string }).commaFixtureSearch ??
  window.location.search;
