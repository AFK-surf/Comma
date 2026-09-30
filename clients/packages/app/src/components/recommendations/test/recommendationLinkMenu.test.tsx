import { describe, expect, it } from "vitest";
import {
  recommendationLinkHrefAttribute,
  resolveRecommendationLinkFromEventTarget,
} from "../recommendationLinkMenu";

function root(html: string) {
  const element = document.createElement("div");
  element.innerHTML = html;
  document.body.append(element);
  return element;
}

describe("resolveRecommendationLinkFromEventTarget", () => {
  it("reads the destination off an inline chip, which is a button and has no href", () => {
    const container = root(
      `<button ${recommendationLinkHrefAttribute}="https://linear.app/comma/issue/COMMA-151"><span>COMMA-151</span></button>`
    );
    const label = container.querySelector("span")!;

    expect(resolveRecommendationLinkFromEventTarget(label, container)).toBe(
      "https://linear.app/comma/issue/COMMA-151"
    );
  });

  it("reads an ordinary anchor in prose", () => {
    const container = root(
      `<p>See <a href="https://example.com/report">report</a></p>`
    );

    expect(
      resolveRecommendationLinkFromEventTarget(container.querySelector("a"), container)
    ).toBe("https://example.com/report");
  });

  it("ignores a target that is not a link", () => {
    const container = root(`<p>Nothing to open here</p>`);

    expect(
      resolveRecommendationLinkFromEventTarget(container.querySelector("p"), container)
    ).toBeNull();
  });

  it("ignores a link outside the root it was asked about", () => {
    const container = root(`<p>inside</p>`);
    const outside = root(`<a href="https://example.com/elsewhere">outside</a>`);

    expect(
      resolveRecommendationLinkFromEventTarget(outside.querySelector("a"), container)
    ).toBeNull();
  });

  it("ignores non-http destinations, which the platform menu is not for", () => {
    const container = root(
      `<button ${recommendationLinkHrefAttribute}="javascript:alert(1)">x</button>`
    );

    expect(
      resolveRecommendationLinkFromEventTarget(
        container.querySelector("button"),
        container
      )
    ).toBeNull();
  });

  it("ignores a same-origin destination, which is a route rather than a link out", () => {
    const container = root(
      `<a href="${window.location.origin}/#/settings">settings</a>`
    );

    expect(
      resolveRecommendationLinkFromEventTarget(container.querySelector("a"), container)
    ).toBeNull();
  });
});
