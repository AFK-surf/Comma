import { describe, expect, it } from "vitest";
import {
  localizeSideChatTestWindowSourceFrame,
  sideChatTestWindowRoute,
  sideChatTestWindowRouteWithSource,
} from "../side-chat-test-window";

describe("Side Chat test window geometry", () => {
  it("converts Electron screen DIPs into the selected display's local coordinates", () => {
    expect(
      localizeSideChatTestWindowSourceFrame(
        { height: 24, width: 24, x: -118, y: 84 },
        { height: 1117, width: 1728, x: -1728, y: 0 }
      )
    ).toEqual({ height: 24, width: 24, x: 1610, y: 84 });
  });

  it("keeps the morph source inside the fullscreen overlay", () => {
    expect(
      localizeSideChatTestWindowSourceFrame(
        { height: 90, width: 90, x: 1435, y: 895 },
        { height: 900, width: 1440, x: 0, y: 0 }
      )
    ).toEqual({ height: 90, width: 90, x: 1350, y: 810 });
  });

  it("encodes only validated local source geometry into the independent route", () => {
    expect(sideChatTestWindowRoute).toBe("/side-chat/test-window");
    expect(
      sideChatTestWindowRouteWithSource({
        height: 30,
        width: 30,
        x: 41.23456,
        y: 84.76543,
      })
    ).toBe(
      "/side-chat/test-window?sourceHeight=30&sourceWidth=30&sourceX=41.235&sourceY=84.765"
    );
  });

  it("encodes a task conversation target alongside the shared morph geometry", () => {
    expect(
      sideChatTestWindowRouteWithSource(
        { height: 120, width: 300, x: 30, y: 140 },
        { conversationId: "cnv_task_1", groupId: "grp_1", workspaceId: "wsp_1" }
      )
    ).toBe(
      "/side-chat/test-window?sourceHeight=120&sourceWidth=300&sourceX=30&sourceY=140&conversationId=cnv_task_1&groupId=grp_1&workspaceId=wsp_1"
    );
  });
});
