defmodule SalixIM.IFCAdminTest do
  @moduledoc """
  The operator-facing assembly of information-flow settings
  (`docs/verification.md` §3.6).

  The dashboard renders whatever this returns, so what is worth testing is the
  shape of the truth it tells: that observed and classified are distinguishable,
  that a classification for a never-seen conversation still appears, and that a
  setting which would be silently misread later is refused here instead.
  """

  use SystemsClock.Case, async: false

  alias SalixIM.IFC.Admin
  alias SalixStore.{Ids, Keys, S3}
  alias SalixStore.IFC, as: Store

  @connect "cnx_admin"

  setup do
    for table <-
          ~w(ifc_scope_labels ifc_tag_clearances ifc_principal_facts ifc_scope_facts ifc_scope_members ifc_receipts) do
      SalixStore.Repo.query!("DELETE FROM #{table}")
    end

    previous_backend = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, S3.Fake)
    if SystemsRuntime.Proc.whereis(S3.Fake), do: S3.Fake.reset(), else: start_supervised!(S3.Fake)

    on_exit(fn ->
      if is_nil(previous_backend),
        do: SystemsRuntime.delete_env(:salix_store, :s3_backend),
        else: SystemsRuntime.put_env(:salix_store, :s3_backend, previous_backend)
    end)

    tenant = Ids.new_tenant_id()
    group = group(tenant, %{})
    {:ok, tenant: tenant, group: group}
  end

  defp group(tenant, ifc) do
    group_id = Ids.new_group_id(tenant)

    record =
      %{
        "group_id" => group_id,
        "tenant_id" => tenant,
        "router_conversation_id" => Ids.new_conversation_id()
      }
      |> then(&if ifc == %{}, do: &1, else: Map.put(&1, "ifc", ifc))

    {:ok, _result} = S3.put(Keys.ctl_group(group_id), Jason.encode!(record))
    group_id
  end

  describe "the overview" do
    test "reports the Group's own mode", %{tenant: tenant} do
      group = group(tenant, %{"mode" => "enforce"})
      assert {:ok, %{"mode" => "enforce"}} = Admin.overview(tenant, group)
    end
  end

  describe "classifying" do
    test "keeps tags, audience and sealed as written", %{tenant: tenant, group: group} do
      assert :ok =
               Admin.put_scope_label(tenant, group, @connect, "C1", %{
                 "tags" => ["counsel", "counsel", " board "],
                 "audience_mode" => "members",
                 "sealed" => true
               })

      assert {:ok, [row]} = Store.list_scope_labels(tenant, group, @connect)
      # The store keeps tags sorted, so a set is a set however it was typed.
      assert row["tags"] == ["board", "counsel"]
      assert row["audience_mode"] == "members"
      assert row["sealed"] == true
    end
  end

  describe "the conversation table" do
  end

  describe "bounds" do
  end

  describe "the conversation window" do
  end

  describe "clearances" do
    test "are stored against the provider principal, and can be withdrawn", %{
      tenant: tenant,
      group: group
    } do
      assert :ok = Admin.put_tag_clearance(tenant, group, @connect, "counsel", "U01")

      assert {:ok, [%{"tag" => "counsel", "principal_key" => key}]} =
               Store.list_tag_clearances(tenant, group, @connect)

      assert key == "provider_user|#{@connect}|U01"

      assert :ok = Admin.delete_tag_clearance(tenant, group, @connect, "counsel", key)
      assert {:ok, []} = Store.list_tag_clearances(tenant, group, @connect)
    end
  end

  describe "placements" do
    test "override the provider, and clear back to it", %{tenant: tenant, group: group} do
      Store.observe_placement(tenant, group, @connect, "U01", "external")

      assert :ok = Admin.put_placement_override(tenant, group, @connect, "U01", "internal")
      assert {:ok, [row]} = Store.list_principal_facts(tenant, group, @connect)
      assert row["placement_observed"] == "external"
      assert row["placement_override"] == "internal"

      # Undoing an override drops the row, so the provider's answer is observed
      # again rather than this page inventing one.
      assert :ok = Admin.put_placement_override(tenant, group, @connect, "U01", "")
      assert {:ok, []} = Store.list_principal_facts(tenant, group, @connect)

      Store.observe_placement(tenant, group, @connect, "U01", "external")
      assert {:ok, [reobserved]} = Store.list_principal_facts(tenant, group, @connect)
      assert reobserved["placement_observed"] == "external"
      assert reobserved["placement_override"] == nil
    end
  end
end
