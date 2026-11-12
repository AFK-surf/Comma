---
name: browser-use
description: Do the task on websites in the Comma in-app browser on the user's computer. Use when the user tags /browser-use.
metadata:
  displayName: Browser use
---

# Browser use

Do this task in the Comma in-app browser. It runs in the user's Comma desktop app, from the user's own network and logins.

1. Resolve the initiating Message's client device and its Comma environment with `device.list` and `device.get`. Run the commands below with `env.exec`.
2. Run `comma describe in-app-browser` to confirm the live schema.
3. `comma call in-app-browser open-tab --json '{"url":"https://..."}'` returns a `tabId`. `list-targets` lists the open tabs.
4. Read the page with `snapshot`. Act with `click`, `fill`, `select`, `press`, `scroll` and `wait`. Each returns a receipt with the page URL, title and a viewport snapshot with refs such as `[e12]`.
5. Send known steps as one `actions` call, for example `{"tabId":"...","steps":[{"op":"fill","ref":"e3","text":"milk"},{"op":"press","key":"Enter"}]}`.
6. A receipt with `dialog` means a JavaScript dialog is open. Answer it with `dialog`.
7. When the site needs the user (a sign-in, a captcha, a payment confirmation), ask the user to do that step in the Comma browser tab, then continue.

Use the in-app browser for this task, not the cloud `browser.*` tools or `web.search`.
If Comma reports that permission is required, ask the user to turn on Allow operations in Settings > Devices.
If no Comma desktop environment is available, tell the user to open the Comma desktop app. Do not do the task another way without asking.
