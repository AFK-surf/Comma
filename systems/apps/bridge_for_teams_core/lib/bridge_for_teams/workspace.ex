defmodule BridgeForTeams.Workspace do
  @moduledoc """
  Read access to a project agent's VFS workspace.

  Salix is the source of truth: workspace files live in the agent's VFS
  manifest (`SalixAgent.Workspace`), read here over `:erpc` through the
  `BridgeForTeams.Salix.Client` seam. The target agent must belong to the
  project — callers name it via `:agent_id` (BridgeForTeams agent uuid) or
  `:salix_agent_id` in `opts`, and the resolution only searches the project's
  own non-archived, provisioned roster; when unnamed, the project's first
  provisioned agent is used (the same resolution as `BridgeForTeams.Sites`).

  Writes go back over the same seam through the existing `write_agent_file`
  callback (see `BridgeForTeams.Sites.publish_project_site/3` / `AssistantChats`
  uploads) — `write_file/3` resolves the project agent identically to the reads
  so a reviewable work product (e.g. an edited email draft the user is about to
  send) can be flushed back to the workspace copy.
  """

  alias BridgeForTeams.Agents
  alias BridgeForTeams.Salix.Client
  alias BridgeForTeams.Schema.{Agent, Project}

  @doc """
  Read one file body from a project agent's workspace.

  Returns `{:ok, binary}`, `{:error, :not_found}` for a missing path,
  `{:error, :agent_not_found}` when the named agent isn't the project's,
  `{:error, :no_agent}` when the project has no provisioned agent, or the
  Salix error (`:unavailable | :timeout | ...`).
  """
  @spec read_file(Project.t(), String.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def read_file(%Project{} = project, path, opts \\ []) when is_binary(path) do
    with {:ok, %Agent{} = agent} <- resolve_agent(project, opts) do
      Client.impl().read_agent_file(agent.salix_agent_id, path)
    end
  end

  @doc """
  List a project agent's workspace entries under `path` (default `"/"`).

  Directories return `{:ok, [entry]}` where each entry is
  `%{"path", "kind" ("file"|"dir"), "size", "modified_at"}`; when `path` names
  a file the runtime answers `{:file, entry}` instead. Agent resolution and
  errors are the same as `read_file/3`.
  """
  @spec list_files(Project.t(), String.t(), keyword()) ::
          {:ok, [map()]} | {:file, map()} | {:error, term()}
  def list_files(%Project{} = project, path \\ "/", opts \\ []) when is_binary(path) do
    with {:ok, %Agent{} = agent} <- resolve_agent(project, opts) do
      Client.impl().list_agent_files(agent.salix_agent_id, path)
    end
  end

  @doc """
  Write `body` to a project agent's workspace at `path`.

  Resolves the target agent exactly like `read_file/3` (the project's first
  provisioned agent unless named via `:agent_id` / `:salix_agent_id` in `opts`),
  then writes over the seam's `write_agent_file` callback. Returns
  `{:ok, result}` (the runtime write receipt), `{:error, :agent_not_found}` /
  `{:error, :no_agent}` for resolution failures, or the Salix write error.
  """
  @spec write_file(Project.t(), String.t(), binary(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def write_file(%Project{} = project, path, body, opts \\ [])
      when is_binary(path) and is_binary(body) do
    with {:ok, %Agent{} = agent} <- resolve_agent(project, opts) do
      Client.impl().write_agent_file(agent.salix_agent_id, path, body)
    end
  end

  defp resolve_agent(%Project{} = project, opts) do
    with {:ok, agents} <- Agents.fetch_agents(project.id) do
      case Keyword.get(opts, :agent_id) || Keyword.get(opts, :salix_agent_id) do
        nil ->
          case agents do
            [agent | _rest] -> {:ok, agent}
            [] -> {:error, :no_agent}
          end

        agent_id ->
          case Enum.find(agents, &(&1.id == agent_id or &1.salix_agent_id == agent_id)) do
            %Agent{} = agent -> {:ok, agent}
            nil -> {:error, :agent_not_found}
          end
      end
    end
  end
end
