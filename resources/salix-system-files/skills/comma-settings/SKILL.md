---
name: comma-settings
description: Know which settings Comma has, where each one is, and who can change it. Use when the user asks whether Comma can be set to do something, where a setting is, or asks you to change a Comma app setting.
---

# Comma Settings

This map tells you which settings Comma has, where they are, and who can change them.
It does not tell you the current value of a setting.
Only a live query can give you the current value.

## Rules

1. Find the setting in the map. Give the user its path in their language: Settings › Category › Setting.
   The Chinese (zh-CN) names are in parentheses.
2. **You (desktop):** you can change the setting when the user asks for it.
   Use the Comma desktop environment of the initiating Message's device, with the `comma-client` skill.
   Run `comma describe global-settings` or `comma describe client-settings`, then `get`, then `update`.
   The live schema is the authority. If it rejects the field, or no Comma desktop environment is available, tell the user the path.
3. **Tool:** use the named tool and its skill.
4. **User:** only the user can change it. Tell the user the path and what the setting does.
   Do not try to change it in a different way, for example through computer use or the in-app browser.
5. If a setting is not in this map, tell the user that Comma does not have that setting.
   Do not make up a path or a workaround. You can name the nearest setting from this map.
6. This map shows the Settings of the desktop app and the web app. **Desktop** rows are only in the desktop app.
   The iOS and Android apps have their own settings pages, which can be different.

## Preferences (偏好设置)

### General (通用)

| Setting | What it does | Who changes it |
| --- | --- | --- |
| Permissions › Label changes (标签修改) | Ask the user, or approve automatically, when you propose Task label changes. | User |
| Tone › Reply style (回复风格) | Default or concise Router replies. | User |
| System prompt › Custom instructions (系统提示词 › 自定义指令) | The owner's custom instructions for the Router. | User |
| Default home view (默认首页) | The page Comma opens on at launch: `home`, `inbox`, `tasks`, `drive`, `apps` or `plugins`. It applies at the next launch. | You (desktop): `client-settings` `defaultHomeView` |
| Language (语言) | System, English or Simplified Chinese. | You (desktop): `client-settings` `localePreference` |
| Launch Comma at login (登录时启动 Comma) | Desktop. | You (desktop): `global-settings` `launchAtLogin` |
| Show in menu bar (在菜单栏中显示) | Desktop. On Windows it is the system tray. | You (desktop): `global-settings` `showInMenuBar` |
| Show in dock (在程序坞中显示) | macOS. | You (desktop): `global-settings` `showInDock` |
| Quick Chat (语音输入) | Desktop. Turns Quick Chat and its shortcut on or off. | You (desktop): `global-settings` `quickChatEnabled` |
| Keep awake with lid closed (合盖保持唤醒) | macOS. Read the `global-settings` description before you change it. | You (desktop): `global-settings` `keepAwakeWhenLidClosed` |
| AirDrop › Show Comma in AirDrop (在 AirDrop 中显示 Comma) | macOS. Also the name that nearby devices see. | You (desktop): `global-settings` `showInAirDrop`, `airDropName` |
| Notch › Show in notch (在刘海中显示) | macOS. Also how far it extends past each side of the notch. | You (desktop): `global-settings` `showInNotch`, `notchSideWidth` |
| Onboarding › Replay onboarding (新手引导 › 重播新手引导) | Shows the first-launch introduction again. | User |

The order of the icon rail has no row in Settings. The user drags items in the rail to change it.
You (desktop): `client-settings` `sidebarNavOrder`.

### Profile (个人资料)

| Setting | What it does | Who changes it |
| --- | --- | --- |
| Avatar, Name | The user's account profile. | User |
| Sign out, Delete account | Account actions. | User |

### Appearance (外观)

| Setting | What it does | Who changes it |
| --- | --- | --- |
| Theme (主题) | Default, light, dark, signal light, signal dark or a custom color. | You (desktop): `client-settings` `appearance` |
| Font (字体), Font size (字体大小) | The interface font and its size. | You (desktop): `client-settings` `appearance` |
| Translucent window (窗口透明) | Desktop. The window background. | You (desktop): `client-settings` `appearance` |
| Use pointer cursors (使用指针光标), Reduce motion (减少动画) | Pointer cursor on buttons, and less animation. | You (desktop): `client-settings` `appearance` |

### Notifications (通知)

| Setting | What it does | Who changes it |
| --- | --- | --- |
| System notifications (系统通知) | Desktop. Needs an operating system permission that only the user can give. | User |
| Router message notifications (Router 消息通知) | Desktop. Notifications for the Router's messages to the user. Works only while system notifications are on. | You (desktop): `global-settings` `notifyRouterMessages` |
| Notification sound (通知铃声) | Desktop. Works only while system notifications are on. | You (desktop): `global-settings` `notificationSound` |
| Request sound (请求提示音) | A sound when a request from another person arrives. | You (desktop): `client-settings` `requestSound` |

### Keyboard shortcuts (键盘快捷键)

| Setting | What it does | Who changes it |
| --- | --- | --- |
| Navigation (导航) | In-app shortcuts. | You (desktop): `client-settings` `appShortcutOverrides` |
| Commands › Open Comma (命令 › 打开 Comma) | Desktop. The global shortcut that opens Comma. | You (desktop): `client-settings` `openCommaShortcut` |
| Commands › Quick Chat (命令 › 语音输入) | Desktop. The Quick Chat shortcut. The row shows only while Quick Chat is on. | You (desktop): `client-settings` `quickChatShortcut` |

### Usage & billing (用量与账单)

Plan, credits balance, buying credits and redeeming codes. User only. Never buy or redeem for the user.

## Work (工作)

| Category | Settings | Who changes it |
| --- | --- | --- |
| Meeting (会议) | Desktop. Start recording (开始录制): reminder or auto. Hide recorder notch for others (隐藏外部录音浮窗), macOS. Smart summary (智能总结). | You (desktop): `client-settings` `meetingStartRecording`, `meetingHideRecorder`, `meetingSmartSummary` |
| Routines (例程) | Personalization, proactive messages (主动提醒), daily schedule (每日定时例程), delivery time (推送时间), data sources. | User |
| Channels (消息渠道) | Connect Telegram, WeChat, Signal, iMessage and Linear. | User |
| Browser (浏览器) | Import sign-ins from another browser, and shared browser logins. | User |
| Labels (标签) | The Task label catalog. | Tool: `im_api.internal.label.propose` asks for a catalog change. The user edits the catalog. |
| Model & API (模型与 API) | Profiles (API keys and subscriptions), Agent models, default Task model (默认 Task 模型), default place to run Tasks (默认任务运行位置). | User. You choose a model for one Task with `agent.models`, not the defaults. |
| Condensed Workspace (精简工作区) | Shared facts for all Agents. Shows only when the Debug switch is on. | User |

## System (系统)

| Category | Settings | Who changes it |
| --- | --- | --- |
| Voice (语音) | Phone numbers, calls, voice agent API keys. | User |
| Computer use (电脑操作) | macOS Accessibility and Screen Recording permissions. | User |
| About (关于) | Version and updates. | User |

## Archived, Shared, Advanced

| Category | Settings | Who changes it |
| --- | --- | --- |
| Archived tasks (已归档任务), Shared tasks (已分享任务) | Lists of Tasks. | User |
| Requests (请求) | Who can send the user requests, invite links, linked chat accounts. | User |
| Apps (应用) | Apps the user added and the access they gave apps. | User. You create apps with the `mini-app-builder` skill. |
| Inbound API (外部接入) | Keys that let other systems send you messages. | Tool: `inbound_api.*`, with the `inbound-api` skill |
| Devices (设备) | Rename or delete a device, local compute. | User |
| Devices › Allow operations (设备 › 允许操作) | Lets Comma act through the device. Off keeps it read-only. | User turns it on. You (desktop) can only turn it off: `devices set-access`. |
| Tailscale | The Group's connection to the user's tailnet. | Tool: `tailnet.*`, with the `tailscale` skill |
| Debug (调试) | Session history, computer use screen, Condensed Workspace settings, voice labs. | You (desktop): `client-settings` `sessionHistoryEnabled`, `computerUseScreenEnabled`, `condensedWorkspaceSettingsVisible`, `voiceLabsEnabled` |
