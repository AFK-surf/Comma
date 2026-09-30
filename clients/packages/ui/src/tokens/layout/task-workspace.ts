/**
 * Task workspace layout tokens — Comma App.
 * Keep overlay dimensions semantic so the component and Storybook stay aligned.
 */
export const taskWorkspaceLayout = {
  filterMenuWidth: 200,
} as const;

export type TaskWorkspaceLayoutKey = keyof typeof taskWorkspaceLayout;
