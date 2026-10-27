import type { useCommaMessages } from "@comma/i18n/react";
import { toolWorkLabel, type ToolWork } from "./toolWorkCopy";

type CommaMessages = ReturnType<typeof useCommaMessages>;

const toolWork = new Map<string, ToolWork>([
  ["fs.read_file", "filesRead"],
  ["fs.stat_file", "filesRead"],
  ["fs.list_files", "filesRead"],
  ["fs.glob", "filesRead"],
  ["fs.grep", "filesRead"],
  ["compute.workspace.read", "filesRead"],
  ["compute.workspace.stat", "filesRead"],
  ["compute.workspace.list", "filesRead"],
  ["fs.write_file", "filesEdit"],
  ["fs.edit_file", "filesEdit"],
  ["compute.workspace.write", "filesEdit"],
  ["fs.copy_file", "filesOrganize"],
  ["fs.move_file", "filesOrganize"],
  ["env.copy", "filesOrganize"],
  ["fs.delete_file", "filesDelete"],
  ["env.exec", "command"],
  ["env.remote_shell", "command"],
  ["compute.exec", "command"],
  ["compute.build.run", "command"],
  ["process.start", "command"],
  ["script.run", "code"],
  ["script.run_file", "code"],
  ["env.computer_use", "computer"],
  ["web.search", "webSearch"],
  ["web.read_pages", "webRead"],
  ["web.http_request", "webRequest"],
  ["im_api.internal.task.create", "taskCreate"],
  ["im_api.internal.task.update", "taskUpdate"],
  ["im_api.internal.update_conversation", "taskUpdate"],
  ["im_api.internal.update_conversation_titles", "taskUpdate"],
  ["im_api.internal.task.list", "taskList"],
  ["im_api.internal.list_conversation_participants", "progress"],
  ["im_api.internal.get_conversation_participant_status", "progress"],
  ["tool_call.get_status", "progress"],
  ["tool_call.get_result", "progress"],
  ["im_api.internal.read_conversation", "messages"],
  ["im_api.internal.search_conversations", "messages"],
  ["history.search", "messages"],
  ["history.list", "messages"],
  ["history.get", "messages"],
  ["im_api.internal.add_agent_participant", "workerAdd"],
  ["agent.list", "workers"],
  ["agent.get", "workers"],
  ["agent.create_worker", "workerCreate"],
  ["agent.update", "workerUpdate"],
  ["agent.rebind_runtime", "workerUpdate"],
  ["agent.archive", "workerUpdate"],
  ["email.send_to_owners", "email"],
  ["composio.execute", "pluginUse"],
  ["composio.list_toolkits", "pluginUse"],
  ["composio.list_tools", "pluginUse"],
  ["composio.get_tool", "pluginUse"],
  ["composio.list_connections", "pluginUse"],
  ["composio.check_connection", "pluginUse"],
  ["composio.delete_connection", "pluginsSetup"],
  ["oauth.request_authorization", "access"],
  ["oauth.complete_authorization", "access"],
  ["composio.request_connection", "access"],
  ["mcp_manager.authorize", "access"],
  ["permission.request", "approval"],
  ["ifc.request_declassification", "approval"],
  ["location.request", "location"],
  ["calendar.list_items", "calendarRead"],
  ["calendar.get_item", "calendarRead"],
  ["calendar.create_event", "calendarWrite"],
  ["calendar.update_context", "calendarWrite"],
  ["meeting.join", "meetingJoin"],
  ["meeting.get", "meetingRead"],
  ["meeting.read_summary_materials", "meetingRead"],
  ["meeting.submit_summary", "meetingNotes"],
  ["schedule.create", "schedule"],
  ["schedule.delete", "schedule"],
  ["proactive.act", "reminderSet"],
  ["proactive.watch", "reminderSet"],
  ["proactive.present", "reminderSend"],
  ["composio.create_trigger", "automation"],
  ["composio.bind_trigger", "automation"],
  ["composio.manage_trigger", "automation"],
  ["composio.list_triggers", "automation"],
  ["composio.list_trigger_types", "automation"],
  ["composio.get_trigger_type", "automation"],
  ["image.generate", "image"],
  ["video.generate", "video"],
  ["audio.transcribe", "audio"],
  ["preview.publish_html", "page"],
  ["cloud_vm.start", "cloudVm"],
  ["ssh.upload", "filesUpload"],
  ["ssh.download", "filesDownload"],
  ["env.process_list", "commandOutput"],
  ["env.process_tail", "commandOutput"],
  ["env.process_write", "commandOutput"],
  ["process.list", "commandOutput"],
  ["process.tail", "commandOutput"],
  ["process.write", "commandOutput"],
  ["process.stop", "commandStop"],
  ["device.lan_discover", "smartHome"],
  ["device.lan_request", "smartHome"],
  ["device.miio_request", "smartHome"],
  ["device.gree_request", "smartHome"],
  ["env.android", "android"],
  ["ui.create", "card"],
  ["question.request", "question"],
  ["compute.service.export", "workspace"],
  ["compute.service.import", "workspace"],
  ["compute.workloads.list", "workspace"],
  ["compute.route.revoke", "workspace"],
  ["schedule.list", "scheduleRead"],
  ["oauth.list_credentials", "credentials"],
  ["oauth.delete_credential", "credentials"],
  ["drive.status", "drive"],
  ["device.list", "devices"],
  ["device.get", "devices"],
  ["memory.search", "memoryRead"],
  ["memory.get", "memoryRead"],
  ["memory.write", "memoryWrite"],
  ["wait_for", "wait"],
]);

// Families whose every operation does the same kind of work. MCP plugin
// operations are named mcp.<binding>.<tool>.
const toolWorkFamilies: ReadonlyArray<readonly [prefix: string, work: ToolWork]> = [
  ["meeting.preparation.", "meetingPrep"],
  ["im_api.internal.label.", "labels"],
  ["mcp_manager.", "pluginsSetup"],
  ["plugin.", "pluginsSetup"],
  ["skill.", "skills"],
  ["ssh.", "remoteServer"],
  ["station.", "station"],
  ["tailnet.", "network"],
  ["loop.", "automation"],
  // The Mac apps on the user's Mac (mcp.mac.<app>_<operation>); the first match wins.
  ["mcp.mac.calendar_list", "calendarRead"],
  ["mcp.mac.calendar_", "calendarWrite"],
  ["mcp.mac.reminders_list", "remindersRead"],
  ["mcp.mac.reminders_", "remindersWrite"],
  ["mcp.mac.contacts_", "contactsRead"],
  ["mcp.mac.messages_send", "macMessageSend"],
  ["mcp.mac.mail_", "emailDraft"],
  ["mcp.mac.notes_create", "notesWrite"],
  ["mcp.mac.notes_", "notesRead"],
  ["mcp.mac.music_", "music"],
  ["mcp.mac.maps_", "maps"],
  ["mcp.mac.system_", "macControl"],
  ["mcp.mac.vision_", "imageRead"],
  ["mcp.", "pluginUse"],
];

// Messaging apps expose provider operations as im_api.<provider>.<operation>.
const messagingWork = new Map<string, readonly [send: ToolWork, use: ToolWork]>([
  ["slack", ["slackSend", "slackUse"]],
  ["telegram", ["telegramSend", "telegramUse"]],
  ["feishu", ["feishuSend", "feishuUse"]],
  ["lark", ["larkSend", "larkUse"]],
  ["wechat", ["wechatSend", "wechatUse"]],
  ["imessage", ["imessageSend", "imessageUse"]],
  ["signal", ["signalSend", "signalUse"]],
]);

// The Router's own bookkeeping between steps: a second or so, and nothing a
// reader follows. While one runs the line stays on what came before it.
const quietTools = new Set([
  "im_api.internal.send_message",
  "device.list",
  "device.get",
  "agent.models",
  "tool_call.cancel",
]);
const quietFamilies = ["recommendation.", "migration."];

// What a call works on, worded with the work: a search's query, the site of
// a page read, the name of a file read.
const targetCopy: ReadonlyMap<
  string,
  (messages: CommaMessages, target: string) => string
> = new Map([
  [
    "web.search",
    (messages, target) => messages.chat_tool_web_search_target({ target }),
  ],
  [
    "web.read_pages",
    (messages, target) => messages.chat_tool_web_read_target({ target }),
  ],
  [
    "fs.read_file",
    (messages, target) => messages.chat_tool_file_read_target({ target }),
  ],
]);

function toolWorkFor(toolName: string): ToolWork | undefined {
  const work =
    toolWork.get(toolName) ??
    toolWorkFamilies.find(([prefix]) => toolName.startsWith(prefix))?.[1];
  if (work) return work;

  const [, provider = "", operation = ""] =
    /^im_api\.([a-z]+)\.(.+)$/.exec(toolName) ?? [];
  const [send, use] = messagingWork.get(provider) ?? [];
  return /^(send|post|reply)_/.test(operation) ? send : use;
}

/**
 * Plain wording, in the reader's language, for the work behind a tool call.
 * A tool identifier is never copy: a tool without wording returns undefined
 * so the caller shows its generic line.
 */
export function toolActivityLabel(
  messages: CommaMessages,
  toolName: string | undefined,
  status: "running" | "failed",
  target?: string | undefined
): string | undefined {
  const name = toolName?.trim();
  if (
    status === "running" &&
    name &&
    (quietTools.has(name) || quietFamilies.some((prefix) => name.startsWith(prefix)))
  )
    return undefined;
  const targeted = name && target?.trim() ? targetCopy.get(name) : undefined;
  if (status === "running" && targeted) return targeted(messages, target!.trim());
  const work = name ? toolWorkFor(name) : undefined;
  if (!work) return undefined;
  return toolWorkLabel(messages, work, status);
}
