defmodule SalixIM.Ports.TaskSchedule do
  @moduledoc false
  @callback update_task_schedule(String.t(), String.t(), map() | nil) ::
              {:ok, map()} | {:error, term()}

  def update_task_schedule(group_id, conversation_id, schedule)
      when is_map(schedule) or is_nil(schedule) do
    if mod = Application.get_env(:salix_im, :task_schedule_mod) do
      mod.update_task_schedule(group_id, conversation_id, schedule)
    else
      {:error, :task_schedule_not_configured}
    end
  end
end
