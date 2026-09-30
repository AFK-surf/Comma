defmodule Comma.ReleaseTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  test "completed Group handoff still finishes late Cloudflare profile conversion" do
    tenant = SalixStore.Ids.new_tenant_id()
    group = SalixStore.Ids.new_group_id(tenant)
    resource = SalixStore.RuntimeIds.cloud_vm_provider_resource_name(group)

    assert {:ok, %{"phase" => "complete"}} = SalixStore.ComputeMigration.state()

    assert {:ok, _, :created} =
             SalixStore.Compute.ensure_group_workload(%{
               "tenant_id" => tenant,
               "group_id" => group,
               "provider" => "cloudflare",
               "provider_resource_id" => resource,
               "provider_resource_name" => resource,
               "provider_spec" => %{},
               "status" => "ready",
               "created_at" => 1_000
             })

    output = capture_io(fn -> assert :ok = Comma.Release.transfer_agent_configuration_page() end)
    cursor = transfer_cursor(output)
    assert %{"stage" => "cloudflare_profile", "source" => nil} = decode_transfer_cursor(cursor)

    cursor =
      transfer_cursor(
        capture_io(fn ->
          assert :ok = Comma.Release.transfer_agent_configuration_page(cursor)
        end)
      )

    assert %{"stage" => "cloudflare_profile", "source" => "claims"} =
             decode_transfer_cursor(cursor)

    assert nil ==
             transfer_cursor(
               capture_io(fn ->
                 assert :ok = Comma.Release.transfer_agent_configuration_page(cursor)
               end)
             )

    assert {:ok, rec} = SalixStore.Compute.group_workload(group)
    assert get_in(rec, ["provider_spec", "profile_key"]) == "cf-standard-2"
  end

  test "stage executor receives only authorized ids when another migration becomes pending" do
    manifest = "sha256:test"
    calls = start_supervised!({Agent, fn -> 0 end})

    plan = fn ->
      n = Agent.get_and_update(calls, &{&1, &1 + 1})

      %{
        manifestDigest: manifest,
        pendingSteps:
          if n == 0 do
            [plan_step("billing-1", "expand")]
          else
            [plan_step("billing-2", "expand")]
          end,
        providerPendingIDs: []
      }
    end

    parent = self()

    assert :ok =
             Comma.Release.execute_plan_stage("online", manifest, ["billing-1"],
               plan: plan,
               online_executor: fn ids ->
                 send(parent, {:executed, ids})
                 :ok
               end
             )

    assert_received {:executed, ["billing-1"]}
    refute_received {:executed, ["billing-2"]}
  end

  test "stage authorization preserves manifest dependency order" do
    manifest = "sha256:test"

    pending_plan = fn ->
      %{
        manifestDigest: manifest,
        pendingSteps: [
          plan_step("comma-20260723000014", "expand"),
          plan_step("comma-20260723000007", "expand")
        ],
        providerPendingIDs: []
      }
    end

    assert_raise RuntimeError, ~r/authorized pending ids drift/, fn ->
      Comma.Release.execute_plan_stage(
        "online",
        manifest,
        ["comma-20260723000007", "comma-20260723000014"],
        plan: pending_plan
      )
    end

    parent = self()
    calls = start_supervised!({Agent, fn -> 0 end})

    converging_plan = fn ->
      n = Agent.get_and_update(calls, &{&1, &1 + 1})

      if n == 0 do
        pending_plan.()
      else
        %{pending_plan.() | pendingSteps: []}
      end
    end

    assert :ok =
             Comma.Release.execute_plan_stage(
               "online",
               manifest,
               ["comma-20260723000014", "comma-20260723000007"],
               plan: converging_plan,
               online_executor: fn ids ->
                 send(parent, {:executed_in_order, ids})
                 :ok
               end
             )

    assert_received {:executed_in_order, ["comma-20260723000014", "comma-20260723000007"]}
  end

  test "an already-applied authorized step is adopted, not treated as drift" do
    # Lost-completion / Job-GC recovery: the controller re-authorizes the salix
    # cutover after its own completion bookkeeping was lost and the Job aged
    # out. The migration ledger already records the step, so the plan shows it
    # no longer pending. execute_plan_stage must adopt it (idempotent no-op via
    # the executor), not raise "authorized pending ids drift".
    manifest = "sha256:test"
    parent = self()

    applied_plan = fn ->
      %{manifestDigest: manifest, pendingSteps: [], providerPendingIDs: []}
    end

    assert :ok =
             Comma.Release.execute_plan_stage(
               "cutover",
               manifest,
               ["salix-20260724000102"],
               plan: applied_plan,
               cutover_executor: fn ids ->
                 send(parent, {:adopted_cutover, ids})
                 :ok
               end
             )

    assert_received {:adopted_cutover, ["salix-20260724000102"]}
  end

  test "a pending step that is not authorized still raises drift" do
    manifest = "sha256:test"

    plan = fn ->
      %{
        manifestDigest: manifest,
        pendingSteps: [plan_step("salix-20260724000102", "exclusive")],
        providerPendingIDs: []
      }
    end

    # Authorizing only an already-applied step while a real step is pending must
    # NOT be adopted away — pending work cannot be skipped.
    assert_raise RuntimeError, ~r/authorized pending ids drift/, fn ->
      Comma.Release.execute_plan_stage("cutover", manifest, ["salix-20991231000001"],
        plan: plan,
        cutover_executor: fn _ids -> :ok end
      )
    end
  end

  test "the authorized-step entrypoint resolves migrations from either directory" do
    # Regression for the hardcoded per-version migration-dir routing: an
    # exclusive salix cutover step lives in priv/release_migrations, an expand
    # step in priv/repo/migrations. The real entrypoint (run_ecto_migration ->
    # authorized_migration_path) must find each in its own directory instead of
    # raising "authorized migration file missing" at zero replicas.
    assert Comma.Release.authorized_migration_path(:salix_store, 20_260_727_000_003) =~
             "priv/release_migrations/20260727000003_provider_credentials_cutover.exs"

    assert Comma.Release.authorized_migration_path(:salix_store, 20_260_724_000_102) =~
             "priv/release_migrations/"

    assert Comma.Release.authorized_migration_path(:salix_store, 20_260_727_000_001) =~
             "priv/repo/migrations/20260727000001_create_composio_settings.exs"

    assert Comma.Release.authorized_migration_path(:alert_router, 20_260_821_000_003) =~
             "priv/repo/migrations/20260821000003_create_alert_router_state.exs"

    assert_raise RuntimeError, ~r/authorized migration file missing/, fn ->
      Comma.Release.authorized_migration_path(:salix_store, 99_999_999_999_999)
    end

    # A :migration_dir override (as with_release_sources sets for the shared
    # ledger tests) redirects the expand base but must NOT hide the app's
    # release-migration directory: an exclusive cutover step still resolves
    # from priv/release_migrations.
    assert Comma.Release.authorized_migration_path(
             :salix_store,
             20_260_727_000_003,
             Application.app_dir(:salix_store, "priv/repo/migrations")
           ) =~ "priv/release_migrations/20260727000003_provider_credentials_cutover.exs"
  end

  test "exclusive Ecto and analytics classifications execute only inside cutover" do
    parent = self()
    schema_ids = ["billing-20991231000001", "analytics-20991231000002"]

    assert :ok =
             Comma.Release.execute_cutover_steps(schema_ids,
               schema_runner: fn ids ->
                 send(parent, {:exclusive_schema, ids})
                 :ok
               end
             )

    assert_received {:exclusive_schema, ^schema_ids}

    assert_raise RuntimeError, ~r/unsupported cutover release steps/, fn ->
      Comma.Release.execute_cutover_steps(["comma-local-seed"])
    end
  end

  test "cutover executes the terminal PostgreSQL marker in the authorized schema batch" do
    parent = self()

    assert :ok =
             Comma.Release.execute_cutover_steps(["comma-20260723000003"],
               schema_runner: fn ids ->
                 send(parent, {:marker_migration, ids})
                 :ok
               end
             )

    assert_received {:marker_migration, ["comma-20260723000003"]}
  end

  defp plan_step(id, phase) do
    %{
      "id" => id,
      "owner" => "test",
      "store" => "postgres",
      "version" => 1,
      "source" => "test",
      "checksum" => "sha256:test",
      "phase" => phase,
      "compatibility" => %{},
      "execution" => %{},
      "safety" => %{},
      "postconditions" => ["test"],
      "repair" => "retry"
    }
  end

  defp transfer_cursor(output) do
    [_, body] = Regex.run(~r/COMMA_AGENT_TRANSFER_RESULT:(\{[^\n]+\})/, output)
    Jason.decode!(body)["next_cursor"]
  end

  defp decode_transfer_cursor(cursor), do: cursor |> Base.decode64!() |> Jason.decode!()
end
