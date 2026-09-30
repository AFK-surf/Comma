defmodule SalixMeet.Ports.AgentRuntime do
  @moduledoc """
  Port from meeting facts to agent-owned meeting runtime storage.

  The meeting app owns meeting records and provider state. Hidden meeting agent
  record/state/workspace commits are agent facts and must be provided by the
  composition host.
  """

  @callback ensure_preparation_worker(String.t(), String.t()) ::
              {:ok, String.t()} | {:error, term()}

  @callback ensure_agent(map()) :: :ok | {:error, term()}
  @callback verify_agent(map()) :: :ok | {:error, term()}
  @callback prepare_workspace_write(String.t(), String.t(), binary()) ::
              {:ok, map()} | {:error, term()}
  @callback discard_prepared_workspace_write(map()) :: :ok | {:error, term()}
  @callback stream_workspace_write(String.t(), String.t(), String.t(), String.t()) ::
              {:ok, map()} | {:error, term()}
  @callback stream_meeting_artifact_write(
              String.t(),
              String.t(),
              String.t(),
              String.t(),
              String.t(),
              non_neg_integer()
            ) :: {:ok, map()} | {:error, term()}
  @callback stat_workspace(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  @callback read_workspace(String.t(), String.t()) :: {:ok, binary()} | {:error, term()}
  @callback stream_workspace_read(String.t(), String.t()) ::
              {:ok, Enumerable.t(), non_neg_integer()} | {:error, term()}
  @callback event_committed?(String.t(), String.t(), String.t()) ::
              {:ok, boolean()} | {:error, term()}
  @callback workspace_event_committed?(String.t(), String.t(), String.t()) ::
              {:ok, boolean()} | {:error, term()}
  @callback commit_event(map()) :: {:ok, :created | :duplicate} | {:error, term()}

  @optional_callbacks ensure_preparation_worker: 2,
                      event_committed?: 3,
                      workspace_event_committed?: 3,
                      stream_meeting_artifact_write: 6,
                      stream_workspace_read: 2,
                      discard_prepared_workspace_write: 1

  def ensure_preparation_worker(group_id, router_id) do
    runtime = impl()

    if Code.ensure_loaded?(runtime) and function_exported?(runtime, :ensure_preparation_worker, 2),
      do: runtime.ensure_preparation_worker(group_id, router_id),
      else: {:error, :meeting_preparation_worker_not_configured}
  end

  def ensure_agent(request), do: impl().ensure_agent(request)
  def verify_agent(request), do: impl().verify_agent(request)

  def prepare_workspace_write(agent_id, path, data),
    do: impl().prepare_workspace_write(agent_id, path, data)

  def discard_prepared_workspace_write(event) do
    runtime = impl()

    if function_exported?(runtime, :discard_prepared_workspace_write, 1),
      do: runtime.discard_prepared_workspace_write(event),
      else: :ok
  end

  def stream_workspace_write(agent_id, env_id, dst_path, src_path),
    do: impl().stream_workspace_write(agent_id, env_id, dst_path, src_path)

  def stream_meeting_artifact_write(
        agent_id,
        env_id,
        dst_path,
        meeting_id,
        source_ref,
        source_size
      ) do
    runtime = impl()

    if function_exported?(runtime, :stream_meeting_artifact_write, 6) do
      runtime.stream_meeting_artifact_write(
        agent_id,
        env_id,
        dst_path,
        meeting_id,
        source_ref,
        source_size
      )
    else
      {:error, :meeting_artifact_stream_not_supported}
    end
  end

  def stat_workspace(agent_id, path), do: impl().stat_workspace(agent_id, path)

  def read_workspace(agent_id, path), do: impl().read_workspace(agent_id, path)

  def stream_workspace_read(agent_id, path) do
    runtime = impl()

    if function_exported?(runtime, :stream_workspace_read, 2),
      do: runtime.stream_workspace_read(agent_id, path),
      else: {:error, :workspace_stream_read_not_supported}
  end

  def event_committed?(agent_id, session_id, source_id) do
    runtime = impl()

    if function_exported?(runtime, :event_committed?, 3) do
      runtime.event_committed?(agent_id, session_id, source_id)
    else
      {:ok, false}
    end
  end

  def workspace_event_committed?(agent_id, session_id, source_id) do
    runtime = impl()

    if function_exported?(runtime, :workspace_event_committed?, 3) do
      runtime.workspace_event_committed?(agent_id, session_id, source_id)
    else
      {:ok, false}
    end
  end

  def commit_event(request), do: impl().commit_event(request)

  defp impl do
    Application.get_env(:salix_meet, :agent_runtime_mod, __MODULE__.None)
  end

  defmodule None do
    @moduledoc false
    @behaviour SalixMeet.Ports.AgentRuntime

    @impl true
    def ensure_agent(_request), do: {:error, :agent_runtime_not_configured}

    @impl true
    def verify_agent(_request), do: {:error, :agent_runtime_not_configured}

    @impl true
    def prepare_workspace_write(_agent_id, _path, _data),
      do: {:error, :agent_runtime_not_configured}

    @impl true
    def stream_workspace_write(_agent_id, _env_id, _dst_path, _src_path),
      do: {:error, :agent_runtime_not_configured}

    @impl true
    def stream_meeting_artifact_write(
          _agent_id,
          _env_id,
          _dst_path,
          _meeting_id,
          _source_ref,
          _source_size
        ),
        do: {:error, :agent_runtime_not_configured}

    @impl true
    def stat_workspace(_agent_id, _path), do: {:error, :agent_runtime_not_configured}

    @impl true
    def read_workspace(_agent_id, _path), do: {:error, :agent_runtime_not_configured}

    @impl true
    def event_committed?(_agent_id, _session_id, _source_id),
      do: {:error, :agent_runtime_not_configured}

    @impl true
    def workspace_event_committed?(_agent_id, _session_id, _source_id),
      do: {:error, :agent_runtime_not_configured}

    @impl true
    def commit_event(_request), do: {:error, :agent_runtime_not_configured}
  end
end
