defmodule SalixStore.AgentConfigurationRollout do
  @moduledoc """
  Canonical Agent admission after the first fence-aware online rollout.

  Only the release runner, after durable core success, publishes this marker.
  Missing/unreadable state blocks management writes, never pod readiness or
  message execution. One indexed read, no cache, timer or runtime node scan.
  Modeled in tla/salix/AgentConfigurationAuthority.tla (Admit/Configure/Create).
  """
  alias SalixStore.Repo
  @marker "agent_configuration_writers_v1"

  def ensure_open do
    case state() do
      {:ok, phase} when phase in [:ready, :complete] -> :ok
      _ -> {:error, :agent_configuration_rollout_pending}
    end
  end

  def state do
    case Repo.query("SELECT evidence->>'phase' FROM salix_cutover_markers WHERE name = $1", [
           @marker
         ]) do
      {:ok, %{rows: []}} -> {:ok, :blocked}
      {:ok, %{rows: [["writers_ready"]]}} -> {:ok, :ready}
      {:ok, %{rows: [["complete"]]}} -> {:ok, :complete}
      {:error, _} -> {:error, :agent_configuration_state_unavailable}
      _ -> {:error, :invalid_agent_configuration_state}
    end
  rescue
    _ -> {:error, :agent_configuration_state_unavailable}
  catch
    :exit, _ -> {:error, :agent_configuration_state_unavailable}
  end

  @doc "Release-only: all old writers have exited; never called by serving admission."
  def open do
    case Repo.query(
           "INSERT INTO salix_cutover_markers (name, completed_at, evidence) " <>
             "VALUES ($1, now(), '{\"phase\":\"writers_ready\"}'::jsonb) ON CONFLICT (name) DO NOTHING",
           [@marker]
         ) do
      {:ok, _} -> ensure_open()
      _ -> {:error, :agent_configuration_rollout_pending}
    end
  end

  @doc "Release-only: the bounded inventory finished without failed transfers."
  def complete do
    case Repo.query(
           "UPDATE salix_cutover_markers SET evidence = '{\"phase\":\"complete\"}'::jsonb " <>
             "WHERE name = $1 AND evidence->>'phase' IN ('writers_ready', 'complete')",
           [@marker]
         ) do
      {:ok, %{num_rows: 1}} -> :ok
      _ -> {:error, :agent_configuration_rollout_pending}
    end
  end
end
