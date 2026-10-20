defmodule SalixMeetNative do
  @moduledoc false

  alias SalixMeetNative.{CodeClaim, Runtime, TokenFactory}

  @supervisor SalixMeetNative.SessionSupervisor

  @spec join(map(), keyword()) :: {:ok, pid(), :started | :reused} | {:error, term()}
  def join(%{"meeting_id" => meeting_id} = request, opts) when is_binary(meeting_id) do
    case String.trim(meeting_id) do
      "" ->
        {:error, :missing_meeting_id}

      meeting_id ->
        code = meeting_code(request["meet_url"])

        case code && :global.whereis_name(code_key(code)) do
          claim when is_pid(claim) ->
            case CodeClaim.owner(claim) do
              owner when is_pid(owner) ->
                # One bot per Meet code. Its events belong to the Meeting that
                # started it, so another Meeting cannot share it.
                reused(owner, meeting_id)

              :undefined ->
                start(Map.put(request, "meeting_id", meeting_id), meeting_id, code, opts)
            end

          _ ->
            start(Map.put(request, "meeting_id", meeting_id), meeting_id, code, opts)
        end
    end
  end

  def join(_request, _opts), do: {:error, :missing_meeting_id}

  @spec leave(String.t()) :: :ok | {:error, :not_found}
  def leave(meeting_id) do
    case :global.whereis_name(key(meeting_id)) do
      :undefined -> {:error, :not_found}
      pid -> Runtime.leave(pid)
    end
  end

  @spec send_chat(String.t(), String.t(), String.t() | nil) :: :ok | {:error, term()}
  def send_chat(meeting_id, text, message_id \\ nil),
    do: call(meeting_id, &Runtime.send_chat(&1, text, message_id))

  @spec session_status(String.t()) :: {:ok, :live | :none}
  def session_status(meeting_id) do
    case :global.whereis_name(key(meeting_id)) do
      pid when is_pid(pid) -> {:ok, :live}
      :undefined -> {:ok, :none}
    end
  end

  @spec local_status(String.t()) :: :live | :none
  def local_status(meeting_id) do
    case :global.whereis_name(key(meeting_id)) do
      pid when is_pid(pid) and node(pid) == node() -> :live
      _ -> :none
    end
  end

  @spec list() :: [String.t()]
  def list do
    for {__MODULE__, meeting_id} <- :global.registered_names(),
        is_binary(meeting_id),
        do: meeting_id
  end

  defp start(request, meeting_id, code, opts) do
    case :global.whereis_name(key(meeting_id)) do
      pid when is_pid(pid) -> {:ok, pid, :reused}
      :undefined -> start_checked(request, meeting_id, code, opts)
    end
  end

  defp start_checked(request, meeting_id, code, opts) do
    names = [name: name(meeting_id), code_name: code && {:global, code_key(code)}]
    spec = {Runtime, opts |> Keyword.merge(names) |> Keyword.put(:request, request)}

    case DynamicSupervisor.start_child(@supervisor, spec) do
      {:ok, pid} -> {:ok, pid, :started}
      {:error, {:already_started, pid}} when is_pid(pid) -> reused(pid, meeting_id)
      {:error, _} = error -> error
    end
  end

  # One bot per Meet code. Its events belong to the Meeting that started it,
  # so another Meeting cannot share it.
  defp reused(pid, meeting_id) do
    if :global.whereis_name(key(meeting_id)) == pid,
      do: {:ok, pid, :reused},
      else: {:error, :meet_in_use}
  end

  defp call(meeting_id, fun) do
    case :global.whereis_name(key(meeting_id)) do
      :undefined -> {:error, :not_found}
      pid -> fun.(pid)
    end
  catch
    :exit, _ -> {:error, :not_found}
  end

  defp meeting_code(url) when is_binary(url) do
    case TokenFactory.normalize_meeting_url(url) do
      {:ok, normalized} -> normalized |> URI.parse() |> Map.get(:path) |> String.trim("/")
      _ -> nil
    end
  end

  defp meeting_code(_url), do: nil

  defp name(meeting_id), do: {:global, key(meeting_id)}
  defp key(meeting_id), do: {__MODULE__, meeting_id}
  defp code_key(code), do: {__MODULE__, :code, code}
end
