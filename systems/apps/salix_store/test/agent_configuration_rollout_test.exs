defmodule SalixStore.AgentConfigurationRolloutTest do
  use ExUnit.Case, async: false

  alias SalixStore.{AgentConfigurationRollout, Repo}

  test "an unreadable marker differs from pending admission and recovers after rollback" do
    before = AgentConfigurationRollout.state()

    assert {:error, :test_complete} =
             Repo.transaction(fn ->
               # Hide application tables on this connection only. No shared schema changes.
               Repo.query!("SET LOCAL search_path TO pg_catalog")

               assert {:error, :agent_configuration_state_unavailable} =
                        AgentConfigurationRollout.state()

               assert {:error, :agent_configuration_rollout_pending} =
                        AgentConfigurationRollout.ensure_open()

               Repo.rollback(:test_complete)
             end)

    assert AgentConfigurationRollout.state() == before
  end

  test "an invalid phase is not a transient read failure and cannot open admission" do
    assert {:error, :test_complete} =
             Repo.transaction(fn ->
               Repo.query!("""
               INSERT INTO salix_cutover_markers (name, completed_at, evidence)
               VALUES ('agent_configuration_writers_v1', now(), '{"phase":"invalid"}'::jsonb)
               ON CONFLICT (name) DO UPDATE SET evidence = EXCLUDED.evidence
               """)

               assert {:error, :invalid_agent_configuration_state} =
                        AgentConfigurationRollout.state()

               assert {:error, :agent_configuration_rollout_pending} =
                        AgentConfigurationRollout.ensure_open()

               Repo.rollback(:test_complete)
             end)
  end
end
