defmodule Salix.Bindings.MeetingAgentRuntime do
  @moduledoc false

  @behaviour SalixMeet.Ports.AgentRuntime
  @max_artifact_bytes 30 * 1024 * 1024

  defmodule ArtifactSizeError do
    @moduledoc false
    defexception [:message]
  end

  @impl true
  def ensure_preparation_worker(group_id, router_id) do
    with {:ok, %{"group_id" => ^group_id, "role" => "router"} = router} <-
           SalixAgent.Control.get_record(router_id),
         {:ok, result} <-
           SalixAgent.AgentManagement.ensure_owned_worker(
             "meeting-preparation",
             %{
               "name" => "Meeting preparation",
               "purpose" => "Prepare source-backed meeting reports and personal reminders",
               "runtime" => %{"kind" => "internal"}
             },
             %{
               agent_id: router_id,
               session_id: router["router_session_id"]
             }
           ) do
      # The existing creation reservation reuses one ordinary Worker for this
      # Router. Its Tasks have separate sessions. No per-meeting Worker fan-out.
      {:ok, result["agent"]["agent_id"]}
    else
      {:error, _} = error -> error
      _ -> {:error, :meeting_preparation_router_required}
    end
  end

  @impl true
  def ensure_agent(request), do: SalixAgent.MeetingRuntime.ensure_agent(request)

  @impl true
  def verify_agent(request), do: SalixAgent.MeetingRuntime.verify_agent(request)

  @impl true
  def prepare_workspace_write(agent_id, path, data),
    do: SalixAgent.MeetingRuntime.prepare_workspace_write(agent_id, path, data)

  @impl true
  def discard_prepared_workspace_write(event),
    do: SalixAgent.AgentWorkspace.discard_prepared_write(event)

  @impl true
  def stream_workspace_write(agent_id, env_id, dst_path, src_path) do
    message = SalixEnv.Protocol.request("read_stream", %{"path" => src_path})

    with {:ok, stream, _size} <-
           SalixEnv.Connector.Live.read_stream(
             env_id,
             message,
             SalixEnv.Protocol.timeout("read_stream", %{})
           ) do
      SalixAgent.MeetingRuntime.prepare_workspace_write_stream(agent_id, dst_path, stream)
    end
  end

  @impl true
  def stream_meeting_artifact_write(
        agent_id,
        env_id,
        dst_path,
        meeting_id,
        source_ref,
        source_size
      ) do
    started_at = System.monotonic_time()

    result =
      with :ok <- validate_source_size(source_size),
           params = %{
             "meeting_id" => meeting_id,
             "source_ref" => source_ref,
             "expected_size" => source_size,
             "max_bytes" => @max_artifact_bytes
           },
           message = SalixEnv.Protocol.request("meeting_artifact_read", params),
           {:ok, stream, reported_size} <-
             SalixEnv.Connector.Live.read_stream(
               env_id,
               message,
               SalixEnv.Protocol.timeout("meeting_artifact_read", params)
             ),
           :ok <- validate_reported_size(reported_size, source_size) do
        SalixAgent.MeetingRuntime.prepare_workspace_write_stream(
          agent_id,
          dst_path,
          bounded_stream(stream, source_size)
        )
      end

    Salix.Telemetry.emit_operation(
      "salix_meet",
      "meeting_artifact",
      "system",
      artifact_outcome(result),
      System.monotonic_time() - started_at
    )

    result
  end

  defp artifact_outcome({:ok, _}), do: "ok"

  defp artifact_outcome({:error, reason}) do
    value = reason |> inspect() |> String.downcase()

    cond do
      String.contains?(value, "timeout") -> "timeout"
      String.contains?(value, "capacity") -> "rejected"
      String.contains?(value, "size") -> "rejected"
      String.contains?(value, "changed") -> "rejected"
      String.contains?(value, "expired") -> "rejected"
      String.contains?(value, "unavailable") -> "unavailable"
      true -> "error"
    end
  end

  defp artifact_outcome(_), do: "error"

  defp validate_source_size(size)
       when is_integer(size) and size >= 0 and size <= @max_artifact_bytes,
       do: :ok

  defp validate_source_size(_size), do: {:error, :artifact_size_limit}

  defp validate_reported_size(nil, _expected_size), do: :ok
  defp validate_reported_size(size, size) when is_integer(size), do: :ok

  defp validate_reported_size(_reported_size, _expected_size),
    do: {:error, :artifact_size_mismatch}

  defp bounded_stream(stream, expected_size) do
    Stream.transform(
      stream,
      fn -> 0 end,
      fn chunk, received when is_binary(chunk) ->
        next = received + byte_size(chunk)

        if next > expected_size or next > @max_artifact_bytes do
          raise ArtifactSizeError,
            message: "meeting artifact stream exceeds its declared or maximum size"
        end

        {[chunk], next}
      end,
      fn received ->
        if received != expected_size do
          raise ArtifactSizeError,
            message: "meeting artifact stream ended before its declared size"
        end

        :ok
      end
    )
  end

  @impl true
  def stat_workspace(agent_id, path),
    do: SalixAgent.MeetingRuntime.stat_workspace(agent_id, path)

  @impl true
  def read_workspace(agent_id, path), do: SalixAgent.MeetingRuntime.read_workspace(agent_id, path)

  @impl true
  def stream_workspace_read(agent_id, path),
    do: SalixAgent.MeetingRuntime.stream_workspace(agent_id, path)

  @impl true
  def event_committed?(agent_id, session_id, source_id),
    do: SalixAgent.MeetingRuntime.event_committed?(agent_id, session_id, source_id)

  @impl true
  def workspace_event_committed?(agent_id, session_id, source_id),
    do: SalixAgent.MeetingRuntime.workspace_event_committed?(agent_id, session_id, source_id)

  @impl true
  def commit_event(request), do: SalixAgent.MeetingRuntime.commit_event(request)
end
