defmodule Comma.ReleaseTenantDirectoryTest do
  use SystemsClock.Case, async: false

  import ExUnit.CaptureIO

  alias Salix.Control.Store
  alias SalixStore.{Ids, Keys, Repo, S3, TenantDirectory, TenantProfiles}

  @marker "tenant_directory_v1"

  setup do
    S3.Fake.reset()
    Repo.query!("DELETE FROM salix_cutover_markers WHERE name = $1", [@marker])
    comma = Ecto.Adapters.SQL.Sandbox.start_owner!(Comma.Repo, shared: true)
    bridge = Ecto.Adapters.SQL.Sandbox.start_owner!(BridgeForTeams.Repo, shared: true)

    on_exit(fn ->
      # The other release tests run with the repos in automatic mode.
      Ecto.Adapters.SQL.Sandbox.stop_owner(comma)
      Ecto.Adapters.SQL.Sandbox.stop_owner(bridge)
      Ecto.Adapters.SQL.Sandbox.mode(Comma.Repo, :auto)
      Ecto.Adapters.SQL.Sandbox.mode(BridgeForTeams.Repo, :auto)
      S3.Fake.reset()
      Repo.query!("DELETE FROM salix_cutover_markers WHERE name = $1", [@marker])
    end)

    :ok
  end

  # A Tenant record as a release before this one wrote it: no product, no row.
  defp old_tenant!(name) do
    id = Ids.new_tenant_id()
    record = %{"tenant_id" => id, "name" => name, "created_at" => 1_800_000_000, "config" => "{}"}
    {:ok, _} = Store.put_new(Keys.ctl_tenant(id), record)
    id
  end

  defp record(id) do
    {:ok, %{body: body}} = S3.get(Keys.ctl_tenant(id))
    Jason.decode!(body)
  end

  test "the post-rollout backfill fills the directory and records each Tenant's product once" do
    workspace_tenant = old_tenant!("Workspace")
    guest_tenant = old_tenant!("Comma guests")
    org_tenant = old_tenant!("Org")
    direct_tenant = old_tenant!("Direct")

    Comma.Repo.insert!(%Comma.Data.User{id: "usr_dir_test", normalized_email: "dir@example.test"})
    group = Ids.new_group_id(workspace_tenant)

    Comma.Repo.insert!(%Comma.Data.Workspace{
      id: "wsp_" <> SystemsRuntime.Proc.uuid(),
      name: "Workspace",
      salix_tenant_id: workspace_tenant,
      salix_group_id: group,
      group_generation: "test-generation",
      salix_router_agent_id: Ids.new_agent_id(group),
      salix_worker_agent_id: Ids.new_agent_id(group),
      billing_owner_id: "billing-dir-test",
      status: "active",
      owner_user_id: "usr_dir_test"
    })

    {:ok, _} = TenantProfiles.put_router_only(guest_tenant, 4)

    %BridgeForTeams.Schema.Organization{}
    |> BridgeForTeams.Schema.Organization.changeset(%{
      name: "Org",
      slug: "dir-org-#{SystemsRuntime.Proc.unique_integer([:positive])}",
      salix_tenant_id: org_tenant,
      billing_account_id: "bridge-ba-dir-test"
    })
    |> BridgeForTeams.Repo.insert!()

    # Pages of two Tenants: the stage runs until the next stage's cursor.
    assert {:ok, %{processed: 2, next: next}} =
             SalixWeb.Migrations.TenantDirectoryBackfill.page(
               nil,
               &Comma.Release.tenant_products/1,
               page: 2
             )

    assert is_binary(next)
    assert run_stage(stage_cursor("tenant_directory"), 0) == "workspace_provisioning"

    assert record(workspace_tenant)["product"] == "comma"
    assert record(guest_tenant)["product"] == "comma"
    assert record(org_tenant)["product"] == "cft"
    refute Map.has_key?(record(direct_tenant), "product")

    assert {:ok, %{"product" => "comma", "name" => "Workspace"}} =
             TenantDirectory.get(workspace_tenant)

    assert {:ok, %{"product" => "comma"}} = TenantDirectory.get(guest_tenant)
    assert {:ok, %{"product" => "cft"}} = TenantDirectory.get(org_tenant)
    assert {:ok, %{"product" => nil, "name" => "Direct"}} = TenantDirectory.get(direct_tenant)

    # Done once: a later release's job runs no page.
    output =
      capture_io(fn ->
        assert :ok =
                 Comma.Release.transfer_agent_configuration_page(stage_cursor("tenant_directory"))
      end)

    assert %{"processed" => 0, "next_cursor" => next_cursor} = result(output)
    assert %{"stage" => "workspace_provisioning"} = decode(next_cursor)
  end

  defp run_stage(cursor, pages) when pages < 100 do
    stage = decode(cursor)["stage"]

    if stage == "tenant_directory" do
      output =
        capture_io(fn -> assert :ok = Comma.Release.transfer_agent_configuration_page(cursor) end)

      run_stage(result(output)["next_cursor"], pages + 1)
    else
      stage
    end
  end

  defp stage_cursor(stage), do: %{"stage" => stage} |> Jason.encode!() |> Base.encode64()
  defp decode(cursor), do: cursor |> Base.decode64!() |> Jason.decode!()

  defp result(output) do
    [_, body] = Regex.run(~r/COMMA_AGENT_TRANSFER_RESULT:(\{[^\n]+\})/, output)
    Jason.decode!(body)
  end
end
