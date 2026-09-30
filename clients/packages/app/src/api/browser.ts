import { z } from "zod";

export const browserBindingSchema = z.object({
  agent_id: z.string(),
  session_id: z.string(),
  status: z.string(),
  control: z.enum(["agent", "handoff_pending", "human", "disconnected"]),
  busy: z.boolean(),
  shared_storage: z.boolean().optional(),
  storage_error: z.string().nullable().optional(),
  updated_at: z.string(),
});
export type BrowserBinding = z.infer<typeof browserBindingSchema>;
export const browserResultSchema = browserBindingSchema.extend({
  tabs: z
    .array(z.object({ tab_id: z.string(), title: z.string(), url: z.string() }))
    .max(32)
    .optional(),
  text: z.string().optional(),
});
export type BrowserResult = z.infer<typeof browserResultSchema>;
export const browserEventSchema = z.object({
  browser: browserBindingSchema,
  can_control: z.boolean(),
  frame: z
    .object({
      data: z.string().max(1_400_000),
      tab_id: z.string(),
      metadata: z
        .object({ deviceWidth: z.number(), deviceHeight: z.number() })
        .passthrough(),
    })
    .nullable(),
});
export type BrowserEvent = z.infer<typeof browserEventSchema>;
export type BrowserInput =
  | { type: "text"; text: string }
  | {
      type: "keyDown" | "keyUp";
      key: string;
      code: string;
      keyCode: number;
      modifiers: number;
    }
  | {
      type: "mousePressed" | "mouseReleased" | "mouseMoved" | "mouseWheel";
      x: number;
      y: number;
      button: "none" | "left" | "right" | "middle";
      clickCount: number;
      buttons?: number;
      modifiers: number;
      deltaX?: number;
      deltaY?: number;
    };
export function browserPath(workspaceId: string, browser?: BrowserBinding) {
  const base = `/v1/comma/workspaces/${encodeURIComponent(workspaceId)}/browsers`;
  return browser
    ? `${base}/${encodeURIComponent(browser.agent_id)}/${encodeURIComponent(browser.session_id)}`
    : base;
}
