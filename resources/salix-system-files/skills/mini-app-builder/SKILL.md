---
name: mini-app-builder
description: Build or change a Comma app (a mini-app) when the user asks for an app, tool, tracker, game or dashboard that people open and use inside Comma. For Routers, which build, publish and manage apps.
---

# Mini-app builder

This skill is for the Router. A Worker or a coding agent does not create apps:
the build Task's coding agent follows the rules in the app's repository
(`AGENTS.md`), not this skill.

A Comma app is a small web app that runs inside Comma (Mac and web). Its source
is a private GitHub repository in the Workspace's connected GitHub account. A
coding Task on a sandbox builds it and deploys preview versions into the Task.

## When to make an app

Make one when the user asks for something they will open again and use: a
tracker, a form, a calculator, a small game, a team dashboard. A one-time answer,
a document or a chart is not an app. A public website is a different feature.

## Build a new app

1. Call `im_api.internal.apps.create` with `name` (short, in the user's
   language) and an optional `description`. Give `repo` only for an existing
   repository that already has `comma-app.json`.
2. Call `im_api.internal.task.create` once, with:
   - `runs_on`: `{kind: "sandbox"}`
   - `repo`: `{owner, name, base_ref: "main"}` from the `apps.create` result
   - `mini_app`: `{app_id}` from the `apps.create` result
   - `content`: what the app does, for whom, its sections (2 to 5, or one) and
     screens, and its data. The app is built as a phone app that the same code
     lays out as an iPad app and a web app. Say which data is per person and
     which is shared. Say if it needs an outside
     service. The template's stack is Node, Vite, TypeScript, React and
     shadcn/ui, and the repository's `AGENTS.md` and `DESIGN.md` say how to
     use it. Name another stack only when the user asks for one.
   - The look, in `content`: "Use Comma's design system" when the user did not
     ask for a look. When they did, in words, a screenshot or a style file
     (design tokens, a stylesheet, a brand guide), describe it with the values
     it gives: colors, fonts, type sizes, corner radius, spacing and density.
     Copy the values in; do not count on the Task opening the file.
3. Tell the user the app is being built in that Task, and give them the `url`
   from the `apps.create` result. Each deploy shows the preview as an app card
   in the Task. Chats outside Comma, such as Signal and Telegram, do not show
   these cards, so the `url` is how the user opens the app from there.
   It runs the latest preview until publication, then the live
   version. It opens only after the first deploy, and only for members of the
   Workspace, who sign in to Comma.

## Find an app

When the user asks where an app is, or names an app you have no `app_id`
for, call `im_api.internal.apps.list`, or `im_api.internal.apps.get` with the
`app_id`. Each app has its `url`, `repo`, `latest_version` (null before the
first deploy, when the `url` shows nothing yet) and `live_version` (null
until publication).

## Change an app

For an installed app, call `apps.remix` before changing its source. For an
owned app:

- While its build Task is open: send the change to that same Task.
- After the app was published: create a new Task as above, with the same
  `repo` and `mini_app` (from `apps.list` or `apps.get`). Do not call
  `apps.create` again.

## Publish and manage an app

Use `im_api.internal.apps.*` for the user's requested app actions. Do not send
users to Comma to click Publish, Share or another app control.

- Read `apps.get {app_id}` first. It returns Versions, capabilities, grants,
  secret names and install settings. Never guess a Version number.
- Publish with `apps.publish {app_id, version, visibility?}` after the build
  Task is ready for review. Comma accepts review, opens a missing pull request,
  merges the deployed commit and makes the Version live. Report success only
  after this call succeeds. Follow a merge refusal before retrying.
- Rename or change visibility with `apps.update {app_id, name?, description?, visibility?}`.
- Share with `apps.link.create {app_id}`. Give the returned share URL.
  Read, replace or revoke it with `apps.link.get`, `apps.link.reset` or
  `apps.link.revoke`. Reset and revoke also remove other Workspaces' installs.
- Roll back with `apps.rollback {app_id, version}`. This changes the live
  Version, without changing the GitHub repository.
- Stop or restart an app with `apps.disable {app_id}` or `apps.enable {app_id}`.
- Delete with `apps.delete {app_id}`. This deletes the app's stored data and
  deployments. The GitHub repository remains.
- Set capability grants with `apps.grants.set {app_id, grants}`.
  An empty list revokes all grants in this Workspace.
- Set or remove backend secrets with `apps.secrets.set {app_id, name, value}`
  or `apps.secrets.delete {app_id, name}`. Never repeat secret values in replies.
- Install a shared app with `apps.install {token, pinned_version?}`.
  Omit `pinned_version` to follow the live Version. Remove it with
  `apps.uninstall {app_id}`.
- Remix a shared app with `apps.remix {token}`. It returns the new app and
  its build Task. Continue changes in that Task.
- Report a problem with `apps.report {app_id, reason}`.

The Router acts within its Workspace. It cannot read or change a member's
private app, manage another Workspace's app, or undo a platform takedown.
An installed app permits local grants and uninstall, not owner actions.

## Refusals

- No GitHub account connected, or it needs a new sign-in: nothing was made.
  Do what the refusal says: call `oauth.request_authorization` for GitHub with
  the scopes it names and one sentence on why. The user sees a card with an
  authorize button in the chat; do not paste a link. When the call returns
  connected, build the app (step 1 again). When the user declines, say that the
  app needs GitHub and stop.
- The Workspace's sandbox limit is full: tell the user, and offer to wait or to
  end another coding Task.
- The app's `url` is for Workspace members. People outside the Workspace need
  the share URL from `apps.link.create`.
