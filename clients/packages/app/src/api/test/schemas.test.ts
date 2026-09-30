import { describe, expect, it } from "vitest";
import {
  commaConversationEventSchema,
  commaConversationPreviewSchema,
  commaConversationSchema,
  salixMessageSchema,
  commaSkillSchema,
  commaTaskSearchResultSchema,
} from "../schemas";

describe("Comma API schemas", () => {
  it("keeps canonical snapshot messages available when participant presentation is malformed", () => {
    const snapshot = {
      type: "snapshot",
      messages: [
        {
          actor_type: "agent",
          kind: "message",
          message_id: "msg1_committed",
          content: [{ type: "text", text: "The committed reply" }],
        },
      ],
      participant_draft: {
        conversation_id: "cnv_1",
        draft_id: "draft_1",
        response_key: "response_1",
        source_message_ids: ["msg1_user"],
        revision: 1,
        text: "The current prefix",
      },
      participant_status: {
        conversation_id: "cnv_1",
        participant_id: "ptp_1",
        state: "stopped",
        status: "",
        updated_at: 2,
      },
    };

    expect(commaConversationEventSchema.parse(snapshot).participant_draft).toEqual(
      snapshot.participant_draft
    );
    expect(
      commaConversationEventSchema.parse({
        ...snapshot,
        participant_status: {
          ...snapshot.participant_status,
          state: "active",
          loop_wake: true,
        },
      }).participant_status?.loop_wake
    ).toBe(true);
    const parsed = commaConversationEventSchema.parse({
      ...snapshot,
      participant_draft: { ...snapshot.participant_draft, revision: -1 },
      participant_status: { ...snapshot.participant_status, state: "invalid" },
    });
    expect(parsed.participant_draft).toBeUndefined();
    expect(parsed.participant_status).toBeUndefined();
    expect(parsed.messages?.[0]?.message_id).toBe("msg1_committed");
  });

  it("preserves canonical Salix Message and actor identity", () => {
    const parsed = salixMessageSchema.parse({
      actor_type: "agent",
      agent_id: "agt1_worker",
      role_label: "worker",
      content: [{ type: "text", text: "Worker result" }],
      kind: "message",
      message_id: "msg1_worker",
    });

    expect(parsed).toMatchObject({
      actor_type: "agent",
      agent_id: "agt1_worker",
      message_id: "msg1_worker",
      role_label: "worker",
    });
  });

  it("preserves historical system authorship as canonical Salix fields", () => {
    const parsed = salixMessageSchema.parse({
      actor_type: "system",
      content: [{ type: "text", text: "负责产品定义" }],
      kind: "message",
      message_id: "msg1_activation",
      role_label: "workflow",
    });

    expect(parsed).toMatchObject({
      actor_type: "system",
      role_label: "workflow",
    });
  });

  it("accepts additive content block shapes without enumerating block types", () => {
    const parsed = salixMessageSchema.parse({
      actor_type: "agent",
      kind: "message",
      message_id: "msg1_1",
      content: [
        {
          type: "conversation_ref",
          conversation_id: "cnv_task",
          kind: "agent_task",
          title: "部署报告",
        },
        {
          type: "future_widget",
          text: "fallback text",
          vendor_payload: { kept: true },
        },
      ],
    });

    expect(parsed.content[1]).toMatchObject({
      type: "future_widget",
      vendor_payload: { kept: true },
    });
  });

  it("keeps Message metadata opaque for client-owned resource references", () => {
    const withoutMetadata = salixMessageSchema.parse({
      actor_type: "agent",
      content: [{ type: "text", text: "ordinary assistant message" }],
      kind: "message",
      message_id: "msg1_without_metadata",
    });
    const withMetadata = salixMessageSchema.parse({
      actor_type: "agent",
      content: [{ type: "text", text: "message with a local resource" }],
      kind: "message",
      message_id: "msg1_with_metadata",
      metadata: {
        local_resource_reference: "comma-local://device/resource",
        private_field: "preserved",
      },
    });

    expect(withoutMetadata.metadata).toBeUndefined();
    expect(withMetadata.metadata).toEqual({
      local_resource_reference: "comma-local://device/resource",
      private_field: "preserved",
    });
  });

  it("accepts additive public skill fields without leaking private content", () => {
    const parsed = commaSkillSchema.parse({
      skill_id: "weekly-summary",
      name: "Weekly Summary",
      description: "Summarize meetings",
      location: "/.runtime/skills/weekly-summary/SKILL.md",
      extra_future_field: true,
    });

    expect(parsed).toMatchObject({
      skill_id: "weekly-summary",
      location: "/.runtime/skills/weekly-summary/SKILL.md",
      extra_future_field: true,
    });
  });

  it("accepts only the shared Salix conversation kinds", () => {
    const base = {
      group_id: "grp1_1",
      id: "cnv_1",
      title: "Thread",
      status: "open",
    };

    expect(commaConversationSchema.parse({ ...base, kind: "user_chat" }).kind).toBe(
      "user_chat"
    );
    expect(commaConversationSchema.parse({ ...base, kind: "agent_task" }).kind).toBe(
      "agent_task"
    );
    expect(() =>
      commaConversationSchema.parse({ ...base, kind: "assistant" })
    ).toThrow();
    expect(() => commaConversationSchema.parse(base)).toThrow();
  });

  it("strips transcript-shaped fields from a Task preview", () => {
    const parsed = commaConversationPreviewSchema.parse({
      activity_status: "idle",
      freshness: { state: "fresh" },
      group_id: "grp1_1",
      id: "cnv_task_public",
      kind: "agent_task",
      messages: [{ message_id: "msg_private" }],
      status: "running",
      title: "Deploy report",
      updated_at: 2,
    });

    expect(parsed).toEqual({
      activity_status: "idle",
      freshness: { state: "fresh" },
      group_id: "grp1_1",
      id: "cnv_task_public",
      kind: "agent_task",
      status: "running",
      title: "Deploy report",
      updated_at: 2,
    });

    expect(() =>
      commaConversationPreviewSchema.parse({
        id: "cnv_task_public",
        group_id: "grp1_1",
        kind: "agent_task",
        status: "running",
        title: "Deploy report",
      })
    ).toThrow();
  });

  it("accepts safe UTF-16 Task snippets and rejects out-of-bounds highlights", () => {
    const parsed = commaTaskSearchResultSchema.parse({
      conversation_id: "cnv_task_public",
      highlights: [{ start: 2, end: 4 }],
      matched_field: "content",
      snippet: "用 🔎 搜索",
      title: "Comma Search",
    });

    expect(parsed).toMatchObject({ highlights: [{ start: 2, end: 4 }] });
    expect(parsed.snippet.slice(2, 4)).toBe("🔎");

    expect(() =>
      commaTaskSearchResultSchema.parse({
        conversation_id: "cnv_task_public",
        highlights: [{ start: 0, end: 99 }],
        matched_field: "content",
        snippet: "short",
        title: "Comma Search",
      })
    ).toThrow();
  });

  it("requires title matches to preserve the full title for stable highlight ranges", () => {
    const title = "🔎 Archive the completed rollout";
    expect(
      commaTaskSearchResultSchema.parse({
        conversation_id: "cnv_task_title",
        highlights: [{ start: 3, end: 10 }],
        matched_field: "title",
        snippet: title,
        title,
      })
    ).toMatchObject({ snippet: title });

    expect(() =>
      commaTaskSearchResultSchema.parse({
        conversation_id: "cnv_task_title",
        highlights: [{ start: 1, end: 8 }],
        matched_field: "title",
        snippet: "…Archive the completed rollout",
        title,
      })
    ).toThrow();
  });

  it("preserves and validates an optional content match for a title hit", () => {
    const title = "调研 Cursor 并制作网页";
    const parsed = commaTaskSearchResultSchema.parse({
      content_match: {
        highlights: [{ start: 7, end: 9 }],
        snippet: "已完成中文简报网页，并附带 HTML",
      },
      conversation_id: "cnv_task_title_and_content",
      highlights: [{ start: 13, end: 15 }],
      matched_field: "title",
      snippet: title,
      title,
    });

    expect(parsed.content_match).toEqual({
      highlights: [{ start: 7, end: 9 }],
      snippet: "已完成中文简报网页，并附带 HTML",
    });

    expect(() =>
      commaTaskSearchResultSchema.parse({
        ...parsed,
        content_match: {
          highlights: [{ start: 0, end: 99 }],
          snippet: "short",
        },
      })
    ).toThrow();
  });
});
