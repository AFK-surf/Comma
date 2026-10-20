---
name: stillfail-show
description: Show evidence of visible work such as a UI, animation or generated image. Use when people need to judge appearance or interaction.
---

# Show visible work

Show the result, not just a description or a request that the user check it themselves. Say what changed, where
the evidence came from and what to look at.

| To judge | Show |
|---|---|
| Layout, spacing, colours, a state | Images, compared at a glance |
| Animation, transitions, a sequence | Short video; a frame strip for detailed study |
| Something to click, type in or resize | Web service via stillfail-jobs |
| Data, diagrams, comparisons or choices | Inline HTML via stillfail-viz |

Images plus a service often work together: quick visual review and a working version to try.

## Images

- In still.fail, attach with `chat_post(files=[…])` and place with `![](after.png)`. Images on one line appear
  side by side at the same height: `![](before.png) ![](after.png)`.
- Images display at most 360×300, opening full size on click. Crop to the changed area; include a full view when
  context matters. Use device scale 2 for sharpness.
- Use distinct filenames per post. PNG for UI/text; JPEG for photos or size constraints. Limit: 10 files, 50 MB each.
- Slack uploads below the text; omit Markdown image syntax and describe what the evidence shows.

## Video

- Place like an image: `![](demo.webm)` shows a still with a play button. Use mp4 (H.264) or webm (VP8/VP9).
  Keep it short, crop to the motion and say what to watch.
- Browser recordings (Playwright/CDP) can drop frames on slow machines. Record and screenshot in separate runs
  to avoid blank frames. For exact motion, pause `document.getAnimations()`, step `currentTime` by 1000/60 ms,
  capture each step and assemble a video or contact sheet. Real-time-dependent motion can instead be slowed with
  CDP `Animation.setPlaybackRate` and recorded live.

## Services and inline HTML

- Use stillfail-jobs to start, verify, share and keep a service available for review.
- Use stillfail-viz for inline charts, diagrams and option widgets (`ember.sendFollowUpMessage` can put a choice
  in the user's composer). Inline HTML runs in still.fail's sandbox/style; it is not evidence of your actual UI.
  Screenshot or serve that UI instead.
- Full-screen pages (promo, player, slideshow) work better as an unplaced attachment or service. Include a
  screenshot/video in the chat so the result is visible immediately.

## Evidence

- Capture the actual build/page with realistic data, intended sizes and light/dark themes. Label mock-ups as proposals.
- Compare before/after at the same size, data and scroll position. Design alternatives should differ in structure,
  not just a few pixels.
- Inspect images and motion frames yourself: check the change is visible, the build/cache is current, the server
  belongs to you, and nothing else broke. Measured values alone do not demonstrate motion.
- Name the environment and branch/commit. State anything not shown, why, and how it can be checked later.
- Send fresh evidence after each revision.
