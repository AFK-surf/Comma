defmodule BridgeForTeams.ContextLifecycleReadBarrierTest do
  require SystemsRuntime.Proc

  @moduledoc """
  The lifecycle visibility fence needs two real PostgreSQL transactions; a
  shared SQL-sandbox connection would serialize for unrelated reasons and
  could not prove the row-lock contract.
  """

  use SystemsClock.Case, async: false

  import Ecto.Query

  alias BridgeForTeams.ContextLifecycle.{Deadlines, Operations, ReadBarrier}
  alias BridgeForTeams.Repo
  alias BridgeForTeams.SourcedContext.{Grounding, Payloads, Publications}

  alias BridgeForTeams.Schema.{
    Agent,
    AuditLog,
    ContextBundle,
    ContextLifecycleRequest,
    Organization,
    OrgMembership,
    ObservabilityEvent,
    Project,
    SlackHistoryImportRun,
    SourcedContextArtifact,
    SourcedContextArtifactSource,
    SourcedContextDerivation,
    SourcedContextObject,
    SourcedContextPublication,
    SourcedContextReviewItem,
    SourcedContextReviewRevision,
    SourcedContextSnapshot,
    User
  }

  test "a lifecycle update cannot return while an authorized context read is active" do
    Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
    suffix = SystemsRuntime.Proc.unique_integer([:positive])

    org =
      %Organization{}
      |> Organization.changeset(%{
        name: "Context read barrier #{suffix}",
        slug: "context-read-barrier-#{suffix}",
        billing_account_id: "context-read-barrier-ba-#{suffix}",
        salix_tenant_id: "context-read-barrier-tenant-#{suffix}"
      })
      |> Repo.insert!()

    bundle =
      %ContextBundle{}
      |> ContextBundle.registration_changeset(%{
        org_id: org.id,
        source_type: "read_barrier_test",
        source_ref: "bundle-#{suffix}",
        classification: "internal",
        policy_ref: "context-policy-v1"
      })
      |> Repo.insert!()
      |> ContextBundle.lifecycle_changeset(%{
        lifecycle_state: "registered",
        subject_index_state: "complete",
        lifecycle_revision: 0
      })
      |> Repo.update!()

    parent = SystemsRuntime.Proc.self()

    reader =
      SystemsRuntime.Task.async(fn ->
        Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)

        try do
          ReadBarrier.run([bundle.id], fn ->
            SystemsRuntime.Proc.send(parent, {:context_read_locked, SystemsRuntime.Proc.self()})

            SystemsRuntime.Proc.receive do
              :release_context_read -> :plaintext_returned
            end
          end)
        after
          Ecto.Adapters.SQL.Sandbox.checkin(Repo)
        end
      end)

    try do
      assert_receive {:context_read_locked, reader_pid}

      updater =
        SystemsRuntime.Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)

          try do
            current = Repo.get!(ContextBundle, bundle.id)

            SystemsRuntime.Proc.send(
              parent,
              {:lifecycle_update_started, SystemsRuntime.Proc.self()}
            )

            result =
              current
              |> ContextBundle.lifecycle_changeset(%{
                lifecycle_state: "erasure_pending",
                subject_index_state: "complete",
                lifecycle_revision: 1
              })
              |> Repo.update()

            SystemsRuntime.Proc.send(
              parent,
              {:lifecycle_update_completed, SystemsRuntime.Proc.self()}
            )

            result
          after
            Ecto.Adapters.SQL.Sandbox.checkin(Repo)
          end
        end)

      assert_receive {:lifecycle_update_started, updater_pid}
      refute_receive {:lifecycle_update_completed, ^updater_pid}, 100

      SystemsRuntime.Proc.send(reader_pid, :release_context_read)
      assert SystemsRuntime.Task.await(reader, :infinity) == :plaintext_returned

      assert {:ok, %ContextBundle{lifecycle_state: "erasure_pending"}} =
               SystemsRuntime.Task.await(updater, :infinity)

      assert_receive {:lifecycle_update_completed, ^updater_pid}

      assert ReadBarrier.run([bundle.id], fn -> :must_not_run end) ==
               {:error, :context_lifecycle_not_ready}
    after
      SystemsRuntime.Proc.send(reader.pid, :release_context_read)
      Repo.delete_all(from(row in ContextBundle, where: row.id == ^bundle.id))
      Repo.delete!(org)
      Ecto.Adapters.SQL.Sandbox.checkin(Repo)
    end
  end

  defmodule AgentReader do
    def get_agent("publication-barrier-agent-" <> suffix = agent_id, _tenant_id) do
      {:ok,
       %{
         "agent_id" => agent_id,
         "group_id" => "publication-barrier-group-#{suffix}",
         "role" => "router",
         "name" => "Publication barrier agent"
       }}
    end
  end
end
