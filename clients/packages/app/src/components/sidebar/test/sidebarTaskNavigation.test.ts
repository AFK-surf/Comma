import { describe, expect, it } from "vitest";
import {
  sidebarTaskConversationId,
  sidebarTaskNavigationTarget,
} from "../sidebarTaskNavigation";

describe("sidebar task navigation", () => {
  it("opens sidebar tasks on the standalone task detail route", () => {
    expect(
      sidebarTaskNavigationTarget({
        conversationId: "conversation-1",
        groupId: "group-1",
        id: "conversation-1",
        label: "Recent task",
        statusBucket: "backlog",
        updatedAt: 1,
        workspaceId: "workspace-1",
      })
    ).toEqual({
      params: {
        conversationId: "conversation-1",
        groupId: "group-1",
        workspaceId: "workspace-1",
      },
      to: "/tasks/$workspaceId/$groupId/$conversationId",
    });
  });

  it("selects a sidebar task only on its standalone task detail route", () => {
    expect(sidebarTaskConversationId("/tasks/workspace-1/group-1/conversation-1")).toBe(
      "conversation-1"
    );
    expect(
      sidebarTaskConversationId("/inbox/workspace-1/group-1/conversation-1")
    ).toBeUndefined();
  });
});
