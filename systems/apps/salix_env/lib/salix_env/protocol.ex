defmodule SalixEnv.Protocol do
  @moduledoc """
  The connector wire envelope — the Salix port of willow's `EnvMessage`
  (`internal/environ/protocol.go`). One JSON object per WebSocket text frame,
  shared by every message in both directions:

      %{
        "id"      => correlation uuid (request/response pairs),
        "type"    => "request" | "response" | "error" | "stream"
                     | "metadata" | "heartbeat",
        "method"  => RPC method ("exec", "read", "write", "computer_use", …),
        "params"  => method params (request),
        "result"  => method result (response),
        "error"   => error string (type "error"),
        "stream"  => %{"channel","data"(base64),"eof","seq"} (incremental output),
        # metadata-only:
        "skills"       => [...],
        "capabilities" => %{...},
        "system_info"  => %{...}   # host facts (OS, hostname, CPU, memory)
      }

  Salix replaces willow's NATS request/reply with a direct BEAM round trip
  (`SalixEnv.Bridge` → the socket-owning process), so the `agent_id` / `async`
  routing fields willow needs for NATS are not part of this envelope. The
  connector protocol itself is otherwise wire-identical, so a willow-style
  connector needs only its transport swapped.

  Per-method timeouts mirror willow's `internal/environ/client.go`.
  """

  @timeouts %{
    "read" => 30_000,
    "write" => 30_000,
    "read_stream" => 60_000,
    "read_ref" => 60_000,
    "meeting_artifact_read" => 90_000,
    "write_stream" => 60_000,
    "delete" => 30_000,
    "stat" => 30_000,
    "list" => 30_000,
    "glob" => 60_000,
    "grep" => 60_000,
    "exec" => 120_000,
    "process_start" => 30_000,
    "process_list" => 30_000,
    "process_write" => 30_000,
    "process_tail" => 35_000,
    "process_stop" => 30_000,
    "http_request" => 120_000,
    "agent_runtime_input" => 30_000,
    # Default for deployments without calendar autojoin (manual joins run in
    # no bounded task). Calendar deployments override this through
    # :protocol_timeouts with a bound derived from their configured
    # task_timeout_ms (ConfigJson.meeting_join_rpc_timeout_ms/1), so the RPC
    # returns strictly before the outer per-group task is killed for every
    # supported budget, not just the 30s default.
    "meeting_join" => 20_000,
    "meeting_session_status" => 15_000,
    "external_runtime_event" => 30_000,
    "external_runtime_events" => 30_000,
    "runtime_probe" => 30_000,
    "runtime_auth_read" => 30_000,
    "runtime_auth_status" => 30_000,
    "runtime_auth_verify" => 30_000,
    "runtime_auth_input_begin" => 30_000,
    "runtime_auth_input_submit" => 30_000,
    "runtime_auth_input_cancel" => 30_000,
    "runtime_auth_login_start" => 30_000,
    "runtime_auth_login_cancel" => 30_000,
    "computer_use" => 600_000,
    # Connector profile switching and cleanup have a combined 200-second budget.
    "android" => 220_000,
    "request_permission" => 30_000
  }

  @default_timeout 30_000
  @meeting_artifact_timeout_contract %{
    setup_ms: 30_000,
    frame_ms: 250,
    request_slop_ms: 30_000,
    finalize_ms: 30_000,
    server_slop_ms: 30_000
  }

  @doc "A fresh correlation id (`req_` + url-safe random)."
  @spec new_id() :: String.t()
  def new_id, do: "req_" <> (:crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false))

  @doc "Build a request envelope for `method` with `params`."
  @spec request(String.t(), map(), String.t() | nil) :: map()
  def request(method, params, id \\ nil) do
    %{"id" => id || new_id(), "type" => "request", "method" => method, "params" => params}
  end

  @doc """
  Default timeout (ms) for `method`. `exec` honors a caller `timeout` (seconds)
  from params when larger than the floor, mirroring willow's user-provided
  exec deadline.
  """
  @spec timeout(String.t(), map()) :: pos_integer()
  def timeout(method, params \\ %{}) do
    base =
      configured_timeout(method) ||
        Map.get(@timeouts, method, @default_timeout) |> scale_timeout()

    cond do
      method == "meeting_artifact_read" ->
        meeting_artifact_timeout(params, base)

      method == "exec" and params["timeout"] ->
        timeout_from_param(params["timeout"], base)

      method == "http_request" and params["timeout_seconds"] ->
        timeout_from_param(params["timeout_seconds"], base)

      true ->
        process_tail_timeout(method, params, base)
    end
  end

  @doc false
  def meeting_artifact_request_timeout(params) when is_map(params) do
    timeout("meeting_artifact_read", params) + meeting_artifact_timeout_contract().request_slop_ms
  end

  @doc false
  def meeting_artifact_timeout_contract do
    configured = Application.get_env(:salix_env, :meeting_artifact_timeout_contract, %{})

    Enum.reduce(@meeting_artifact_timeout_contract, %{}, fn {key, default}, acc ->
      value = Map.get(configured, key, Map.get(configured, Atom.to_string(key), default))
      Map.put(acc, key, if(valid_contract_ms?(value), do: value, else: default))
    end)
  end

  defp process_tail_timeout("process_tail", params, base) do
    case params["wait_seconds"] do
      secs when is_integer(secs) and secs > 0 -> timeout_from_param(secs, base)
      secs when is_binary(secs) -> timeout_from_param(secs, base)
      _ -> base
    end
  end

  defp process_tail_timeout(_method, _params, base), do: base

  # Reverse streams are stop-and-wait at 64 KiB/frame. Budget 250 ms/frame
  # plus fixed setup/storage slop so every byte count accepted by the meeting
  # envelope remains achievable even when ACKs are deliberately delayed.
  defp meeting_artifact_timeout(params, base) do
    contract = meeting_artifact_timeout_contract()

    case params["expected_size"] do
      size when is_integer(size) and size >= 0 ->
        frames = div(size + 65_535, 65_536)
        max(base, contract.setup_ms + frames * contract.frame_ms)

      _ ->
        base
    end
  end

  defp valid_contract_ms?(value), do: is_integer(value) and value >= 0

  defp timeout_from_param(secs, base) when is_integer(secs) and secs > 0,
    do: max(base, secs * 1000 + 5_000)

  defp timeout_from_param(secs, base) when is_binary(secs),
    do: exec_timeout_from_string(secs, base)

  defp timeout_from_param(_secs, base), do: base

  defp configured_timeout(method) do
    :salix_env
    |> Application.get_env(:protocol_timeouts, %{})
    |> configured_timeout(method)
  end

  defp configured_timeout(overrides, method) when is_map(overrides) do
    overrides
    |> Map.get(method)
    |> positive_timeout()
  end

  defp configured_timeout(_, _), do: nil

  defp positive_timeout(timeout) when is_integer(timeout) and timeout > 0, do: timeout

  defp positive_timeout(timeout) when is_binary(timeout) do
    case Integer.parse(timeout) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

  defp positive_timeout(_), do: nil

  defp exec_timeout_from_string(secs, base) do
    case Integer.parse(secs) do
      {n, _} when n > 0 -> max(base, n * 1000 + 5_000)
      _ -> base
    end
  end

  defp scale_timeout(ms) do
    factor = Application.get_env(:salix_env, :timeout_factor, 1)

    cond do
      is_integer(factor) and factor > 0 -> ms * factor
      is_float(factor) and factor > 0 -> round(ms * factor)
      true -> ms
    end
  end

  @doc "Encode an envelope to a JSON string (a single WebSocket text frame)."
  @spec encode(map()) :: String.t()
  def encode(message), do: Jason.encode!(message)

  @doc "Decode one frame. `{:ok, map}` or `{:error, reason}` (never raises)."
  @spec decode(binary()) :: {:ok, map()} | {:error, term()}
  def decode(frame) do
    case Jason.decode(frame) do
      {:ok, %{} = m} -> {:ok, m}
      {:ok, other} -> {:error, {:not_an_object, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Interpret a decoded response envelope as an RPC outcome:
  `{:ok, result_map}` | `{:error, error_string}`.
  """
  @spec outcome(map()) :: {:ok, map()} | {:error, String.t()}
  def outcome(%{"type" => "error"} = m), do: {:error, m["error"] || "remote error"}
  def outcome(%{"error" => e}) when is_binary(e) and e != "", do: {:error, e}

  def outcome(%{"result" => result}) when is_map(result), do: {:ok, result}
  def outcome(%{"result" => result}), do: {:ok, %{"value" => result}}
  def outcome(_), do: {:ok, %{}}
end
