defmodule SalixIM.Ports.TaskPanelDismissals do
  @moduledoc """
  The Task Panel Dismissals of a User, as Salix IM reaches their owner
  (`Comma.TaskPanelDismissals`, in the product). Salix cannot depend on the
  product, so the product sets the module that implements this behaviour at
  start (`config :salix_im, :task_panel_dismissals`). Without it, `dismiss/2`
  answers `{:error, :task_panel_unavailable}`.

  `dismiss/2` clears each Task from that User's chat Task panel, at the run
  named by `revision`. It is idempotent and never moves a revision back.
  """

  @callback dismiss(user_id :: String.t(), [%{String.t() => term()}]) ::
              {:ok, [map()]} | {:error, term()}

  def dismiss(user_id, dismissals) do
    case SystemsRuntime.get_env(:salix_im, :task_panel_dismissals) do
      nil -> {:error, :task_panel_unavailable}
      module -> module.dismiss(user_id, dismissals)
    end
  end
end
