defmodule SalixStore.IFCTest do
  use ExUnit.Case, async: false

  alias SalixStore.IFC

  @tenant "tnt_ifc"
  @group "grp_ifc"
  @connect "cnx_1"

  setup do
    for table <-
          ~w(ifc_scope_labels ifc_tag_clearances ifc_principal_facts ifc_scope_facts ifc_scope_members ifc_receipts) do
      SalixStore.Repo.query!("DELETE FROM #{table}")
    end

    :ok
  end

  describe "operator configuration" do
    test "a scope label round-trips and every write advances the revision" do
      assert {:ok, 1} =
               IFC.put_scope_label(@tenant, @group, @connect, "C1", %{
                 tags: ["finance", "finance", ""],
                 audience_mode: "members",
                 sealed: true
               })

      assert {:ok, 2} =
               IFC.put_scope_label(@tenant, @group, @connect, "C1", %{tags: ["legal"]})

      assert {:ok, %{"C1" => scope}} = IFC.scopes(@tenant, @group, @connect, ["C1"])
      assert scope.tags == ["legal"]
      assert scope.audience_mode == "space"
      assert scope.sealed == false
      assert scope.revision == 2

      assert :ok = IFC.delete_scope_label(@tenant, @group, @connect, "C1")
      assert {:ok, %{}} == IFC.scopes(@tenant, @group, @connect, ["C1"])
    end

    test "an unknown audience mode or placement is refused" do
      assert {:error, :invalid_audience_mode} =
               IFC.put_scope_label(@tenant, @group, @connect, "C1", %{audience_mode: "whatever"})

      assert {:error, :invalid_placement} =
               IFC.put_principal_fact(@tenant, @group, @connect, "U1", "maybe")
    end

    test "clearances are per tag and per principal" do
      assert {:ok, 1} =
               IFC.put_tag_clearance(@tenant, @group, @connect, "finance", "provider_user|w|U1")

      assert {:ok, 1} =
               IFC.put_tag_clearance(@tenant, @group, @connect, "finance", "provider_user|w|U2")

      assert {:ok, 1} =
               IFC.put_tag_clearance(@tenant, @group, @connect, "legal", "provider_user|w|U1")

      assert {:ok, clearances} =
               IFC.tag_clearances(@tenant, @group, @connect, ["finance", "legal", "exec"])

      assert Enum.sort(clearances["finance"].members) == [
               "provider_user|w|U1",
               "provider_user|w|U2"
             ]

      assert clearances["legal"].members == ["provider_user|w|U1"]
      assert clearances["exec"] == %{members: [], revision: 0}

      assert :ok =
               IFC.delete_tag_clearance(
                 @tenant,
                 @group,
                 @connect,
                 "finance",
                 "provider_user|w|U2"
               )

      assert {:ok, %{"finance" => %{members: ["provider_user|w|U1"]}}} =
               IFC.tag_clearances(@tenant, @group, @connect, ["finance"])
    end

    test "placement overrides are read back per user" do
      assert {:ok, 1} = IFC.put_principal_fact(@tenant, @group, @connect, "U1", "external")
      assert {:ok, 2} = IFC.put_principal_fact(@tenant, @group, @connect, "U1", "internal")

      assert {:ok, %{"U1" => "internal"}} =
               IFC.placement_overrides(@tenant, @group, @connect, ["U1", "U2"])

      assert :ok = IFC.delete_principal_fact(@tenant, @group, @connect, "U1")
      assert {:ok, %{}} == IFC.placement_overrides(@tenant, @group, @connect, ["U1"])
    end

    test "reads are scoped to one tenant and group" do
      assert {:ok, _} = IFC.put_scope_label(@tenant, @group, @connect, "C1", %{tags: ["finance"]})
      assert {:ok, %{}} == IFC.scopes("other_tenant", @group, @connect, ["C1"])
      assert {:ok, %{}} == IFC.scopes(@tenant, "other_group", @connect, ["C1"])
      assert {:ok, %{}} == IFC.scopes(@tenant, @group, "other_connect", ["C1"])
    end
  end

  describe "membership projection" do
    test "an unenumerated scope is unknown, an enumerated empty one is empty" do
      assert {:ok, _} =
               IFC.observe_scope(@tenant, @group, @connect, "C1", %{
                 kind: "room",
                 within: "space"
               })

      assert {:ok, %{"C1" => scope}} = IFC.scopes(@tenant, @group, @connect, ["C1"])
      assert scope.kind == "room"
      assert scope.within == "space"
      assert scope.members == :unknown

      assert {:ok, _} = IFC.replace_scope_members(@tenant, @group, @connect, "C1", [])
      assert {:ok, %{"C1" => scope}} = IFC.scopes(@tenant, @group, @connect, ["C1"])
      assert scope.members == []
    end

    test "join and leave events maintain the set and the revision" do
      assert {:ok, _} = IFC.observe_scope(@tenant, @group, @connect, "C1", %{kind: "room"})

      assert {:ok, revision} =
               IFC.replace_scope_members(@tenant, @group, @connect, "C1", ["u1", "u2"])

      assert {:ok, next} = IFC.add_scope_member(@tenant, @group, @connect, "C1", "u3")
      assert next > revision

      assert {:ok, %{"C1" => %{members: ["u1", "u2", "u3"]}}} =
               IFC.scopes(@tenant, @group, @connect, ["C1"])

      assert {:ok, _} = IFC.remove_scope_member(@tenant, @group, @connect, "C1", "u2")

      assert {:ok, %{"C1" => %{members: ["u1", "u3"]}}} =
               IFC.scopes(@tenant, @group, @connect, ["C1"])
    end

    test "adding a member twice is idempotent" do
      assert {:ok, _} = IFC.replace_scope_members(@tenant, @group, @connect, "C1", ["u1"])
      assert {:ok, _} = IFC.add_scope_member(@tenant, @group, @connect, "C1", "u1")
      assert {:ok, %{"C1" => %{members: ["u1"]}}} = IFC.scopes(@tenant, @group, @connect, ["C1"])
    end

    test "invalidation returns the scope to unknown without losing its structure" do
      assert {:ok, _} = IFC.observe_scope(@tenant, @group, @connect, "C1", %{kind: "shared"})
      assert {:ok, _} = IFC.replace_scope_members(@tenant, @group, @connect, "C1", ["u1"])
      assert {:ok, _} = IFC.invalidate_scope_members(@tenant, @group, @connect, "C1")

      assert {:ok, %{"C1" => scope}} = IFC.scopes(@tenant, @group, @connect, ["C1"])
      assert scope.kind == "shared"
      assert scope.members == :unknown
    end

    test "an unknown scope kind is refused" do
      assert {:error, :invalid_scope_kind} =
               IFC.observe_scope(@tenant, @group, @connect, "C1", %{kind: "space"})
    end
  end

  describe "receipts" do
    test "a valid receipt is readable by its requester until it expires" do
      assert :ok =
               IFC.put_receipt(@tenant, @group, "r1", %{
                 requester_key: "provider_user|w|U1",
                 source_atoms: ["scope|w|D1"],
                 destination_atoms: ["scope|w|C1"],
                 expires_at_ms: 1_000
               })

      assert {:ok, [receipt]} = IFC.receipts(@tenant, @group, ["provider_user|w|U1"], 999)
      assert receipt["id"] == "r1"
      assert receipt["sources"] == ["scope|w|D1"]
      assert receipt["destination"] == ["scope|w|C1"]

      assert {:ok, []} = IFC.receipts(@tenant, @group, ["provider_user|w|U1"], 1_000)
      assert {:ok, []} = IFC.receipts(@tenant, @group, ["provider_user|w|U2"], 999)
    end

    test "a receipt without an expiry never expires" do
      assert :ok =
               IFC.put_receipt(@tenant, @group, "r2", %{
                 requester_key: "provider_user|w|U1",
                 source_atoms: ["scope|w|D1"],
                 destination_atoms: ["group|g"]
               })

      assert {:ok, [_receipt]} =
               IFC.receipts(@tenant, @group, ["provider_user|w|U1"], 9_999_999_999)
    end

    test "an incomplete receipt is refused" do
      assert {:error, :invalid_requester} =
               IFC.put_receipt(@tenant, @group, "r3", %{
                 source_atoms: ["a"],
                 destination_atoms: ["b"]
               })

      assert {:error, :invalid_sources} =
               IFC.put_receipt(@tenant, @group, "r3", %{
                 requester_key: "provider_user|w|U1",
                 destination_atoms: ["b"]
               })

      assert {:error, :invalid_destination} =
               IFC.put_receipt(@tenant, @group, "r3", %{
                 requester_key: "provider_user|w|U1",
                 source_atoms: ["a"]
               })
    end

    test "pruning drops only expired rows" do
      assert :ok =
               IFC.put_receipt(@tenant, @group, "old", %{
                 requester_key: "provider_user|w|U1",
                 source_atoms: ["a"],
                 destination_atoms: ["b"],
                 expires_at_ms: 10
               })

      assert :ok =
               IFC.put_receipt(@tenant, @group, "live", %{
                 requester_key: "provider_user|w|U1",
                 source_atoms: ["a"],
                 destination_atoms: ["b"],
                 expires_at_ms: 100
               })

      assert {:ok, 1} = IFC.prune_receipts(50)

      assert {:ok, [%{"id" => "live"}]} =
               IFC.receipts(@tenant, @group, ["provider_user|w|U1"], 60)
    end
  end
end
