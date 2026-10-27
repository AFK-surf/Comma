import type { useCommaMessages } from "@comma/i18n/react";

type CommaMessages = ReturnType<typeof useCommaMessages>;

/**
 * The kinds of work behind the tools an agent calls, as [running, failed]
 * copy. Tools that do the same kind of work share one line: a reader follows
 * what is happening, not which tool does it.
 */
const workCopy = {
  filesRead: ["chat_tool_files_read", "chat_tool_files_read_failed"],
  filesEdit: ["chat_tool_files_edit", "chat_tool_files_edit_failed"],
  filesOrganize: ["chat_tool_files_organize", "chat_tool_files_organize_failed"],
  filesDelete: ["chat_tool_files_delete", "chat_tool_files_delete_failed"],
  command: ["chat_tool_command", "chat_tool_command_failed"],
  code: ["chat_tool_code", "chat_tool_code_failed"],
  computer: ["chat_tool_computer", "chat_tool_computer_failed"],
  workspace: ["chat_tool_workspace", "chat_tool_workspace_failed"],
  cloudVm: ["chat_tool_cloud_vm", "chat_tool_cloud_vm_failed"],
  remoteServer: ["chat_tool_remote_server", "chat_tool_remote_server_failed"],
  filesUpload: ["chat_tool_files_upload", "chat_tool_files_upload_failed"],
  filesDownload: ["chat_tool_files_download", "chat_tool_files_download_failed"],
  commandOutput: ["chat_tool_command_output", "chat_tool_command_output_failed"],
  commandStop: ["chat_tool_command_stop", "chat_tool_command_stop_failed"],
  station: ["chat_tool_station", "chat_tool_station_failed"],
  smartHome: ["chat_tool_smart_home", "chat_tool_smart_home_failed"],
  android: ["chat_tool_android", "chat_tool_android_failed"],
  card: ["chat_tool_card", "chat_tool_card_failed"],
  question: ["chat_tool_question", "chat_tool_question_failed"],
  network: ["chat_tool_network", "chat_tool_network_failed"],
  scheduleRead: ["chat_tool_schedule_read", "chat_tool_schedule_read_failed"],
  credentials: ["chat_tool_credentials", "chat_tool_credentials_failed"],
  drive: ["chat_tool_drive", "chat_tool_drive_failed"],
  webSearch: ["chat_tool_web_search", "chat_tool_web_search_failed"],
  webRead: ["chat_tool_web_read", "chat_tool_web_read_failed"],
  webRequest: ["chat_tool_web_request", "chat_tool_web_request_failed"],
  taskCreate: ["chat_tool_task_create", "chat_tool_task_create_failed"],
  taskUpdate: ["chat_tool_task_update", "chat_tool_task_update_failed"],
  taskList: ["chat_tool_task_list", "chat_tool_task_list_failed"],
  progress: ["chat_tool_progress", "chat_tool_progress_failed"],
  messages: ["chat_tool_messages", "chat_tool_messages_failed"],
  labels: ["chat_tool_labels", "chat_tool_labels_failed"],
  workerAdd: ["chat_tool_worker_add", "chat_tool_worker_add_failed"],
  workers: ["chat_tool_workers", "chat_tool_workers_failed"],
  workerCreate: ["chat_tool_worker_create", "chat_tool_worker_create_failed"],
  workerUpdate: ["chat_tool_worker_update", "chat_tool_worker_update_failed"],
  email: ["chat_tool_email", "chat_tool_email_failed"],
  slackSend: ["chat_tool_slack_send", "chat_tool_slack_send_failed"],
  slackUse: ["chat_tool_slack_use", "chat_tool_slack_use_failed"],
  telegramSend: ["chat_tool_telegram_send", "chat_tool_telegram_send_failed"],
  telegramUse: ["chat_tool_telegram_use", "chat_tool_telegram_use_failed"],
  feishuSend: ["chat_tool_feishu_send", "chat_tool_feishu_send_failed"],
  feishuUse: ["chat_tool_feishu_use", "chat_tool_feishu_use_failed"],
  larkSend: ["chat_tool_lark_send", "chat_tool_lark_send_failed"],
  larkUse: ["chat_tool_lark_use", "chat_tool_lark_use_failed"],
  wechatSend: ["chat_tool_wechat_send", "chat_tool_wechat_send_failed"],
  wechatUse: ["chat_tool_wechat_use", "chat_tool_wechat_use_failed"],
  imessageSend: ["chat_tool_imessage_send", "chat_tool_imessage_send_failed"],
  imessageUse: ["chat_tool_imessage_use", "chat_tool_imessage_use_failed"],
  signalSend: ["chat_tool_signal_send", "chat_tool_signal_send_failed"],
  signalUse: ["chat_tool_signal_use", "chat_tool_signal_use_failed"],
  pluginUse: ["chat_tool_plugin_use", "chat_tool_plugin_use_failed"],
  pluginsSetup: ["chat_tool_plugins_setup", "chat_tool_plugins_setup_failed"],
  access: ["chat_tool_access", "chat_tool_access_failed"],
  skills: ["chat_tool_skills", "chat_tool_skills_failed"],
  approval: ["chat_tool_approval", "chat_tool_approval_failed"],
  location: ["chat_tool_location", "chat_tool_location_failed"],
  calendarRead: ["chat_tool_calendar_read", "chat_tool_calendar_read_failed"],
  calendarWrite: ["chat_tool_calendar_write", "chat_tool_calendar_write_failed"],
  remindersRead: ["chat_tool_reminders_read", "chat_tool_reminders_read_failed"],
  remindersWrite: ["chat_tool_reminders_write", "chat_tool_reminders_write_failed"],
  contactsRead: ["chat_tool_contacts_read", "chat_tool_contacts_read_failed"],
  macMessageSend: ["chat_tool_mac_message_send", "chat_tool_mac_message_send_failed"],
  emailDraft: ["chat_tool_email_draft", "chat_tool_email_draft_failed"],
  notesRead: ["chat_tool_notes_read", "chat_tool_notes_read_failed"],
  notesWrite: ["chat_tool_notes_write", "chat_tool_notes_write_failed"],
  music: ["chat_tool_music", "chat_tool_music_failed"],
  maps: ["chat_tool_maps", "chat_tool_maps_failed"],
  macControl: ["chat_tool_mac_control", "chat_tool_mac_control_failed"],
  imageRead: ["chat_tool_image_read", "chat_tool_image_read_failed"],
  meetingJoin: ["chat_tool_meeting_join", "chat_tool_meeting_join_failed"],
  meetingRead: ["chat_tool_meeting_read", "chat_tool_meeting_read_failed"],
  meetingNotes: ["chat_tool_meeting_notes", "chat_tool_meeting_notes_failed"],
  meetingPrep: ["chat_tool_meeting_prep", "chat_tool_meeting_prep_failed"],
  schedule: ["chat_tool_schedule", "chat_tool_schedule_failed"],
  reminderSet: ["chat_tool_reminder_set", "chat_tool_reminder_set_failed"],
  reminderSend: ["chat_tool_reminder_send", "chat_tool_reminder_send_failed"],
  automation: ["chat_tool_automation", "chat_tool_automation_failed"],
  image: ["chat_tool_image", "chat_tool_image_failed"],
  video: ["chat_tool_video", "chat_tool_video_failed"],
  audio: ["chat_tool_audio", "chat_tool_audio_failed"],
  page: ["chat_tool_page", "chat_tool_page_failed"],
  devices: ["chat_tool_devices", "chat_tool_devices_failed"],
  memoryRead: ["chat_tool_memory_read", "chat_tool_memory_read_failed"],
  memoryWrite: ["chat_tool_memory_write", "chat_tool_memory_write_failed"],
  wait: ["chat_tool_wait"],
} as const satisfies Record<
  string,
  readonly [keyof CommaMessages] | readonly [keyof CommaMessages, keyof CommaMessages]
>;

export type ToolWork = keyof typeof workCopy;

/** A kind of work in the reader's language, while it runs or once it failed. */
export function toolWorkLabel(
  messages: CommaMessages,
  work: ToolWork,
  status: "running" | "failed"
): string | undefined {
  const [running, failed] = workCopy[work];
  if (status === "running") return messages[running]();
  return failed && messages[failed]();
}
