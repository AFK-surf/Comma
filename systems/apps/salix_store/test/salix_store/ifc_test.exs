defmodule SalixStore.IFCTest do
  use SystemsClock.Case, async: false

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
  end
end
