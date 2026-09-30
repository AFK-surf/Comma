/** No application imports: this is the task window's first paint. */
export function showTaskWindowBoot(): Promise<void> | undefined {
  const [route, query] = location.hash.split("?");
  const params = new URLSearchParams(query);
  if (
    route !== "#/side-chat/test-window" ||
    !["workspaceId", "groupId", "conversationId"].every((key) =>
      params.get(key)?.trim()
    )
  )
    return undefined;

  document.documentElement.dataset.commaWindowRole = "side-chat-test";
  document.body.dataset.commaWindowRole = "side-chat-test";
  const boot = document.createElement("div");
  boot.id = "comma-task-window-boot";
  boot.className = "comma-side-chat-test-window comma-task-window-boot";
  boot.dataset.windowContent = "task-chat";
  boot.dataset.expanded = "false";
  boot.setAttribute("aria-busy", "true");
  const shell = document.createElement("div");
  shell.className = "comma-side-chat-test-shell";
  const placeholder = document.createElement("div");
  placeholder.className = "comma-task-window-placeholder";
  placeholder.setAttribute("aria-hidden", "true");
  shell.append(placeholder);
  boot.append(shell);
  document.body.append(boot);
  const sourceWidth = Number(params.get("sourceWidth"));
  const sourceHeight = Number(params.get("sourceHeight"));
  const sourceX = Number(params.get("sourceX"));
  const sourceY = Number(params.get("sourceY"));
  // One layout read before the first paint; all following frames use only
  // transform. Keep the source rectangle, not just a centered entrance.
  shell.style.setProperty(
    "--task-source-transform",
    `translate(-50%, -50%) translate(${sourceX + sourceWidth / 2 - innerWidth / 2}px, ${sourceY + sourceHeight / 2 - innerHeight / 2}px) scale(${sourceWidth / shell.offsetWidth}, ${sourceHeight / shell.offsetHeight})`
  );
  // The host is already shown before this document loads. Paint the opaque
  // source rectangle, then start the transition on the following paint.
  // TaskWindowEntrance.tla: PaintSource -> StartEntrance -> FinishEntrance.
  return new Promise<void>((resolve) => {
    requestAnimationFrame(() => {
      requestAnimationFrame(() => {
        boot.dataset.expanded = "true";
        const animations = boot.getAnimations({ subtree: true });
        void Promise.allSettled(animations.map((animation) => animation.finished)).then(
          () => resolve()
        );
      });
    });
  });
}
