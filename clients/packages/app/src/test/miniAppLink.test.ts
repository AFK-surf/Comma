import { describe, expect, it, vi } from "vitest";
import { adoptMiniAppLinkLocation, miniAppLinkTokenFromLocation } from "../miniAppLink";

describe("an app link", () => {
  it("is read from the /a/<token> path the page opened at, or the hash route it moved to", () => {
    expect(
      miniAppLinkTokenFromLocation({ pathname: "/a/Tok_en-123456", hash: "" })
    ).toBe("Tok_en-123456");
    expect(
      miniAppLinkTokenFromLocation({ pathname: "/", hash: "#/apps/link/Tok_en-123456" })
    ).toBe("Tok_en-123456");
    expect(
      miniAppLinkTokenFromLocation({ pathname: "/", hash: "#/apps" })
    ).toBeUndefined();
    expect(
      miniAppLinkTokenFromLocation({ pathname: "/a/../x", hash: "" })
    ).toBeUndefined();
  });

  it("moves to its hash route at boot, so sign-in and reloads keep it", () => {
    const history = { replaceState: vi.fn() };
    adoptMiniAppLinkLocation({ pathname: "/a/Tok_en-123456", hash: "" }, history);
    expect(history.replaceState).toHaveBeenCalledWith(
      null,
      "",
      "/#/apps/link/Tok_en-123456"
    );
    history.replaceState.mockClear();
    adoptMiniAppLinkLocation({ pathname: "/", hash: "#/tasks" }, history);
    expect(history.replaceState).not.toHaveBeenCalled();
  });
});
