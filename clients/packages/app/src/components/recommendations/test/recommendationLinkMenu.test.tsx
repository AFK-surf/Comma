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
  it.each([
    {
      name: "reads the destination off an inline chip, which is a button and has no href",
      html: `<button ${recommendationLinkHrefAttribute}="https://linear.app/comma/issue/COMMA-151"><span>COMMA-151</span></button>`,
      target: "span",
      expected: "https://linear.app/comma/issue/COMMA-151",
    },
    {
      name: "reads an ordinary anchor in prose",
      html: `<p>See <a href="https://example.com/report">report</a></p>`,
      target: "a",
      expected: "https://example.com/report",
    },
    {
      name: "ignores a target that is not a link",
      html: `<p>Nothing to open here</p>`,
      target: "p",
      expected: null,
    },
    {
      name: "ignores non-http destinations, which the platform menu is not for",
      html: `<button ${recommendationLinkHrefAttribute}="javascript:alert(1)">x</button>`,
      target: "button",
      expected: null,
    },
    {
      name: "ignores a same-origin destination, which is a route rather than a link out",
      html: `<a href="${window.location.origin}/#/settings">settings</a>`,
      target: "a",
      expected: null,
    },
  ])("$name", ({ expected, html, target }) => {
    const container = root(html);

    expect(
      resolveRecommendationLinkFromEventTarget(
        container.querySelector(target),
        container
      )
    ).toBe(expected);
  });

  it("ignores a link outside the root it was asked about", () => {
    const container = root(`<p>inside</p>`);
    const outside = root(`<a href="https://example.com/elsewhere">outside</a>`);

    expect(
      resolveRecommendationLinkFromEventTarget(outside.querySelector("a"), container)
    ).toBeNull();
  });
});
