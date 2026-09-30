defmodule SalixMeet.RuntimeDriver do
  @moduledoc """
  Boundary from the meeting agent actor into the concrete meeting runtime.

  The runtime is responsible for joining the meeting and later calling Salix
  back with `meeting_runtime_update` / `joiner_event` events. The configured
  driver may be a module exporting `join/1` or a one-arity function.
  """

  @callback join(map()) :: :ok | {:ok, map()} | {:error, term()}

  @doc "Whether the configured runtime driver is callable."
  @spec configured?() :: boolean()
  def configured? do
    case Application.get_env(:salix_meet, :runtime_driver) do
      mod when is_atom(mod) and mod != __MODULE__ ->
        Code.ensure_loaded?(mod) and function_exported?(mod, :join, 1) and
          (not function_exported?(mod, :configured?, 0) or mod.configured?())

      fun when is_function(fun, 1) ->
        true

      _ ->
        false
    end
  end

  @doc "Request the external meeting runtime to join one meeting."
  @spec join(map()) :: :ok | {:ok, map()} | {:error, term()}
  def join(meeting_doc) when is_map(meeting_doc) do
    case Application.get_env(:salix_meet, :runtime_driver) do
      nil ->
        {:error, :runtime_driver_not_configured}

      mod when is_atom(mod) ->
        if Code.ensure_loaded?(mod) and function_exported?(mod, :join, 1) do
          mod.join(meeting_doc)
        else
          {:error, {:invalid_runtime_driver, mod}}
        end

      fun when is_function(fun, 1) ->
        fun.(meeting_doc)

      other ->
        {:error, {:invalid_runtime_driver, other}}
    end
  end
end

defmodule SalixMeet.RuntimeDriver.HTTP do
  @moduledoc """
  HTTP implementation of `SalixMeet.RuntimeDriver`.

  Configure `:salix_meet, :runtime_base_url`. The runtime receives the meeting
  identity, join metadata, and callback endpoint, then posts progress back to
  Salix.
  """

  @behaviour SalixMeet.RuntimeDriver

  @doc false
  def configured? do
    case URI.parse(runtime_base_url()) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] ->
        is_binary(host) and String.trim(host) != ""

      _ ->
        false
    end
  end

  @impl true
  def join(meeting_doc) do
    base = runtime_base_url()

    if base == "" do
      {:error, :meeting_runtime_url_not_configured}
    else
      url = base <> "/v1/meetings/join"
      payload = join_payload(meeting_doc)

      case Req.post(url, json: payload) do
        {:ok, %{status: status, body: body}} when status in 200..299 ->
          {:ok, normalize_body(body)}

        {:ok, %{status: status, body: body}} ->
          {:error, "meeting runtime join failed: HTTP #{status} #{inspect(body)}"}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp join_payload(%{"id" => meeting_id, "state" => state} = doc) do
    state = stringify(state || %{})
    group_id = trim(state["group_id"])

    %{
      "meeting_id" => meeting_id,
      "tenant_id" => state["tenant_id"],
      "group_id" => group_id,
      "meeting_agent_id" => state["meeting_agent_id"],
      "meeting_session_id" => state["meeting_session_id"],
      "provider" => state["provider"],
      "connect_id" => state["connect_id"],
      "meet_url" => state["meet_url"],
      "title" => state["title"],
      "caption_language" => state["caption_language"],
      "runtime_token" => state["runtime_token"],
      "runtime_ref" => state["runtime_ref"],
      "runtime_source" => state["runtime_source"],
      "runtime_policy" => state["runtime_policy"],
      "compute_environment_id" => state["compute_environment_id"],
      "workload_id" => state["workload_id"],
      "attempt" => state["attempt"],
      "artifact_root" => state["artifact_root"],
      "join_requested_at" => doc["join_requested_at"],
      "callback_url" => callback_url(group_id)
    }
  end

  defp callback_url(""), do: ""

  defp callback_url(group_id) do
    public_base_url() <>
      "/v1/agent-groups/" <>
      URI.encode(group_id, &URI.char_unreserved?/1) <> "/meeting-agent/runtime-events"
  end

  defp public_base_url do
    SalixMeet.Ports.PublicURL.base_url()
  end

  defp runtime_base_url do
    Application.get_env(:salix_meet, :runtime_base_url)
    |> trim()
    |> String.trim_trailing("/")
  end

  defp normalize_body(body) when is_map(body), do: stringify(body)
  defp normalize_body(body), do: %{"body" => body}

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value

  defp trim(value), do: String.trim(to_string(value || ""))
end
