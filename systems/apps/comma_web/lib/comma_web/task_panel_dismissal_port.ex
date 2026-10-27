defmodule CommaWeb.TaskPanelDismissalPort do
  @moduledoc "Salix IM's way to `Comma.TaskPanelDismissals` (`:salix_im, :task_panel_dismissals`)."
  @behaviour SalixIM.Ports.TaskPanelDismissals

  @impl true
  def dismiss(user_id, dismissals), do: Comma.TaskPanelDismissals.dismiss(user_id, dismissals)
end
