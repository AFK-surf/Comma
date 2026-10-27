import { render } from "@comma/test-utils/render";
import { describe, expect, it } from "vitest";
import { MessageAvatar } from "../rows/MessageAvatar";

describe("MessageAvatar", () => {
  it("wears Comma's mark for a runtime message even with a Worker role", () => {
    const { container } = render(<MessageAvatar actorRole="worker" system preview />);

    expect(container.querySelector('[data-slot="comma-product-mark"]')).not.toBeNull();
    expect(container.querySelector(".comma-worker-model-mark")).toBeNull();
    expect(container.querySelectorAll("svg")).toHaveLength(1);
  });
});
