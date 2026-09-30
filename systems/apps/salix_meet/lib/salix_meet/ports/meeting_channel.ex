defmodule SalixMeet.Ports.MeetingChannel do
  @moduledoc false

  @type target :: %{required(String.t()) => term()}

  @callback resolve(group :: map()) :: {:ok, target()} | {:error, term()}
  @callback ensure_root(group :: map(), meeting_id :: String.t(), event :: map(), target()) ::
              {:ok, String.t()} | {:error, term()}

  @optional_callbacks ensure_root: 4

  @spec resolve(map()) :: {:ok, target()} | {:error, term()}
  def resolve(group), do: impl().resolve(group)

  @spec ensure_root(map(), String.t(), map(), target()) ::
          {:ok, String.t()} | {:error, term()}
  def ensure_root(group, meeting_id, event, target) do
    implementation = impl()

    cond do
      function_exported?(implementation, :ensure_root, 4) ->
        implementation.ensure_root(group, meeting_id, event, target)

      thread_ts = nonblank(target["thread_ts"]) ->
        {:ok, thread_ts}

      true ->
        {:error, :meeting_root_not_supported}
    end
  end

  defp impl, do: Application.get_env(:salix_meet, :meeting_channel_mod, __MODULE__.None)

  defmodule None do
    @moduledoc false
    @behaviour SalixMeet.Ports.MeetingChannel

    @impl true
    def resolve(_group), do: {:error, :not_configured}
  end

  defp nonblank(nil), do: nil

  defp nonblank(value) do
    case value |> to_string() |> String.trim() do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
