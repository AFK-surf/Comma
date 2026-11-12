defmodule SalixStore.SessionWorkNotifications do
  @moduledoc """
  Postgres address hints for committed Session revisions.

  A hint can be lost, duplicated, or reordered. The committed Session due
  index supplies catch-up. A hint never grants execution authority.
  """

  @channel "salix_session_work_v1"
  @version 1
  @max_payload_bytes 7_900
  @max_agent_id_bytes 256
  @max_session_id_bytes 256

  @type notification :: %{
          version: 1,
          revision: non_neg_integer(),
          agent_id: String.t(),
          runtime: :internal,
          session_id: String.t()
        }

  @doc "Fixed lowercase Postgres channel for the v1 payload contract."
  @spec channel() :: String.t()
  def channel, do: @channel

  @doc "Encode the committed Session address into one bounded v1 JSON payload."
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

  @doc "Send a lossy hint after the Session transaction commits."
  def publish(agent_id, session_id, revision) do
    with {:ok, payload} <-
           encode(%{
             agent_id: agent_id,
             runtime_kind: "internal",
             session_id: session_id,
             revision: revision
           }),
         {:ok, _} <- SalixStore.Repo.query("SELECT pg_notify($1, $2)", [@channel, payload]) do
      expect_delivery(payload)
    else
      {:error, _} -> :ok
    end
  rescue
    _error in [DBConnection.ConnectionError, Postgrex.Error] -> :ok
  catch
    :exit, _reason -> :ok
  end

  @listener :"Elixir.SalixCluster.SessionWorkNotificationListener"

  @doc """
  After a commit that published `payload`, tells a test clock that the
  listener of this node has a notification on its way. Nothing happens
  without a listener or a test clock.
  """
  @spec expect_delivery(String.t()) :: :ok
  def expect_delivery(payload) when is_binary(payload) do
    if SystemsRuntime.Proc.whereis(@listener), do: SystemsClock.expect_signal({@channel, payload})
    :ok
  end

  @doc "The listener received `payload`; see `expect_delivery/1`."
  @spec delivered(String.t()) :: :ok
  def delivered(payload) when is_binary(payload),
    do: SystemsClock.signal_arrived({@channel, payload})

  @doc "Decode and strictly validate one v1 notification payload."
  @spec decode(String.t()) :: {:ok, notification()} | {:error, :invalid}
  def decode(payload) when is_binary(payload) and byte_size(payload) <= @max_payload_bytes do
    with {:ok,
          %{
            "v" => @version,
            "revision" => revision,
            "agent_id" => agent_id,
            "runtime_kind" => runtime_kind,
            "session_id" => session_id
          } = decoded} <- Jason.decode(payload),
         true <- map_size(decoded) == 5,
         true <- is_integer(revision) and revision >= 0,
         true <- bounded_binary?(agent_id, @max_agent_id_bytes),
         true <- runtime_kind == "internal",
         true <- bounded_binary?(session_id, @max_session_id_bytes) do
      {:ok,
       %{
         version: @version,
         revision: revision,
         agent_id: agent_id,
         runtime: :internal,
         session_id: session_id
       }}
    else
      _ -> {:error, :invalid}
    end
  end

  def decode(_payload), do: {:error, :invalid}

  defp identity(record) do
    revision = record["revision"] || record[:revision]
    agent_id = record["agent_id"] || record[:agent_id]
    runtime_kind = record["runtime_kind"] || record[:runtime_kind]
    session_id = record["session_id"] || record[:session_id]
    runtime_kind = if is_atom(runtime_kind), do: Atom.to_string(runtime_kind), else: runtime_kind

    with true <- is_integer(revision) and revision >= 0,
         true <- bounded_binary?(agent_id, @max_agent_id_bytes),
         true <- runtime_kind == "internal",
         true <- bounded_binary?(session_id, @max_session_id_bytes) do
      {:ok,
       %{
         "v" => @version,
         "revision" => revision,
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
