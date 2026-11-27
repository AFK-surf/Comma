defmodule SalixIM.TaskStatus do
  @moduledoc """
  Canonical lifecycle status vocabulary for Conversations (`agent_task` and `user_chat`).

  `Conversation.status` is the single authoritative lifecycle field. Ordinary
  Conversation updates may write only non-archive canonical statuses; archiving
  and restoring go exclusively through `SalixIM.TaskArchive`.
  """

  @ordinary_mutable ~w(active ready_for_review escalated completed failed cancelled)
  @archivable ~w(ready_for_review completed failed cancelled escalated)
  @terminal ~w(completed failed cancelled archived)
  @canonical @ordinary_mutable ++ ["archived"]

  @spec canonical() :: [String.t()]
  def canonical, do: @canonical

  @spec ordinary_mutable() :: [String.t()]
  def ordinary_mutable, do: @ordinary_mutable

  @spec archivable() :: [String.t()]
  def archivable, do: @archivable

  @spec terminal() :: [String.t()]
  def terminal, do: @terminal

  @spec valid?(term()) :: boolean()
  def valid?(status) when is_binary(status), do: status in @canonical
  def valid?(_), do: false

  @spec ordinary_mutable?(term()) :: boolean()
  def ordinary_mutable?(status) when is_binary(status), do: status in @ordinary_mutable
  def ordinary_mutable?(_), do: false

  @spec archivable?(term()) :: boolean()
  def archivable?(status) when is_binary(status), do: status in @archivable
  def archivable?(_), do: false

  @spec terminal?(term()) :: boolean()
  def terminal?(status) when is_binary(status), do: status in @terminal
  def terminal?(_), do: false

  @spec validate_ordinary_update(map(), map()) ::
          :ok | {:error, {:conflict | :bad_request, String.t()}}
  def validate_ordinary_update(_conversation, updates) when not is_map_key(updates, "status"),
    do: :ok

  def validate_ordinary_update(_conversation, %{"status" => "archived"}) do
    {:error, {:conflict, "Use im_api.internal.task.archive or the Task archive operation"}}
  end

  def validate_ordinary_update(_conversation, %{"status" => status})
      when is_binary(status) do
    if status in @ordinary_mutable do
      :ok
    else
      {:error, {:bad_request, invalid_ordinary_status_message(status)}}
    end
  end

  def validate_ordinary_update(_conversation, %{"status" => _other}) do
    {:error, {:bad_request, "status must be a string"}}
  end

  @spec invalid_ordinary_status_message(String.t()) :: String.t()
  def invalid_ordinary_status_message(status) when is_binary(status) do
    "invalid status #{inspect(status)}; allowed values: #{Enum.join(@ordinary_mutable, ", ")} (use im_api.internal.task.archive to archive)"
  end
end
