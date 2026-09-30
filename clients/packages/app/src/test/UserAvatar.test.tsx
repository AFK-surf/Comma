import { render, screen } from "@comma/test-utils/render";
import { describe, expect, it } from "vitest";
import { getUserDisplayName, UserAvatar } from "../components/UserAvatar";

describe("UserAvatar", () => {
  it("prefers the display name and renders its initials", () => {
    render(<UserAvatar displayName="  Ada Lovelace  " email="ada@example.com" />);

    expect(screen.getByLabelText("Ada Lovelace")).toHaveTextContent("AL");
    expect(
      getUserDisplayName({ displayName: "  Ada Lovelace  ", email: "ada@example.com" })
    ).toBe("Ada Lovelace");
  });

  it("falls back to the email username when no display name is available", () => {
    render(<UserAvatar email="casey@example.com" />);

    expect(screen.getByLabelText("casey")).toHaveTextContent("C");
    expect(getUserDisplayName({ email: "casey@example.com" })).toBe("casey");
  });
});
