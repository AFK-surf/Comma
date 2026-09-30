defmodule SalixStore.SessionWorkNotifications do
  @moduledoc """
  Versioned Postgres invalidation payload for durable Session work candidates.

  `SessionWorkCandidates.insert/1` publishes this payload with `pg_notify` in
  the same Postgres transaction as the immutable candidate row. The signal is
  an address-only hint: it may be lost, duplicated, reordered, or observed
  before the authoritative Session S3 CAS. Consumers must never delete a
  candidate or infer Session state from it.

  Runtime-ready payloads request catch-up against the existing locator and
  candidate projections. They carry no execution authority. Implementation
  tests cover publication and recovery; the notification TLA+ model is retired.
  """

  @channel "salix_session_work_v1"
  @version 1
  @max_payload_bytes 7_900
  @max_token_bytes 512
  @max_agent_id_bytes 256
  @max_session_id_bytes 256

  @type notification :: %{
          version: 1,
          candidate_token: String.t(),
          agent_id: String.t(),
          runtime: :internal | :external,
          session_id: String.t()
        }

  @doc "Fixed lowercase Postgres channel for the v1 payload contract."
  @spec channel() :: String.t()
  def channel, do: @channel

  @doc "Encode the exact candidate identity into one bounded v1 JSON payload."
  @spec encode(map()) :: {:ok, String.t()} | {:error, :invalid}
  def encode(%{} = record) do
    with {:ok, identity} <- identity(record),
         {:ok, payload} <- Jason.encode(identity),
         true <- byte_size(payload) <= @max_payload_bytes do
      {:ok, payload}
    else
      _ -> {:error, :invalid}
    end
  end

  def encode(_record), do: {:error, :invalid}

  @doc false
  @spec encode!(map()) :: String.t()
  def encode!(record) do
    case encode(record) do
      {:ok, payload} -> payload
      {:error, :invalid} -> raise ArgumentError, "invalid session-work notification"
    end
  end

  @doc "Signal that the durable runtime-ready projection has new eligible work."
  def runtime_ready_payload, do: ~s({"v":1,"kind":"runtime_ready"})

  @doc "Decode and strictly validate one v1 notification payload."
  @spec decode(String.t()) :: {:ok, notification() | :runtime_ready} | {:error, :invalid}
  def decode(~s({"v":1,"kind":"runtime_ready"})), do: {:ok, :runtime_ready}

  def decode(payload) when is_binary(payload) and byte_size(payload) <= @max_payload_bytes do
    with {:ok,
          %{
            "v" => @version,
            "token" => token,
            "agent_id" => agent_id,
            "runtime_kind" => runtime_kind,
            "session_id" => session_id
          } = decoded} <- Jason.decode(payload),
         true <- map_size(decoded) == 5,
         true <- bounded_binary?(token, @max_token_bytes),
         true <- bounded_binary?(agent_id, @max_agent_id_bytes),
         true <- runtime_kind in ["internal", "external"],
         true <- bounded_binary?(session_id, @max_session_id_bytes) do
      {:ok,
       %{
         version: @version,
         candidate_token: token,
         agent_id: agent_id,
         runtime: String.to_existing_atom(runtime_kind),
         session_id: session_id
       }}
    else
      _ -> {:error, :invalid}
    end
  end

  def decode(_payload), do: {:error, :invalid}

  defp identity(record) do
    token = record["token"] || record[:token]
    agent_id = record["agent_id"] || record[:agent_id]
    runtime_kind = record["runtime_kind"] || record[:runtime_kind]
    session_id = record["session_id"] || record[:session_id]
    runtime_kind = if is_atom(runtime_kind), do: Atom.to_string(runtime_kind), else: runtime_kind

    with true <- bounded_binary?(token, @max_token_bytes),
         true <- bounded_binary?(agent_id, @max_agent_id_bytes),
         true <- runtime_kind in ["internal", "external"],
         true <- bounded_binary?(session_id, @max_session_id_bytes) do
      {:ok,
       %{
         "v" => @version,
         "token" => token,
         "agent_id" => agent_id,
         "runtime_kind" => runtime_kind,
         "session_id" => session_id
       }}
    else
      _ -> {:error, :invalid}
    end
  end

  defp bounded_binary?(value, max_bytes),
    do: is_binary(value) and value != "" and byte_size(value) <= max_bytes
end
