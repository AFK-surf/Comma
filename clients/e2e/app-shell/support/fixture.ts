import { testPage } from "./virtual-time";

/**
 * Mounts a fixture module the way its index.html loaded it: in the test's own
 * page (./child), on a fresh document body, with the URL's query visible to
 * the fixture.
 */
export function fixtureMount(moduleUrl: URL, body = '<div id="root"></div>') {
  return (url: URL) => testPage().mount(moduleUrl.href, url.search, body);
}
