defmodule Comma.Data.TaskPanelDismissal do
  @moduledoc false
  use Ecto.Schema

  @primary_key false
  schema "comma_task_panel_dismissals" do
    field(:user_id, :string, primary_key: true)
    field(:task_id, :string, primary_key: true)
    field(:revision, :integer)
    field(:dismissed_at, :utc_datetime_usec)
  end
end
