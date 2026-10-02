defmodule SalixIM.IFCAdminTest do
  @moduledoc """
  The operator-facing assembly of information-flow settings
  (`docs/verification.md` §3.6).

  The dashboard renders whatever this returns, so what is worth testing is the
  shape of the truth it tells: that observed and classified are distinguishable,
  that a classification for a never-seen conversation still appears, and that a
  setting which would be silently misread later is refused here instead.
  """

  use ExUnit.Case, async: false

  alias SalixIM.IFC.Admin
  alias SalixStore.{Ids, Keys, S3}
  alias SalixStore.IFC, as: Store

  @connect "cnx_admin"

  setup do
    for table <-
          ~w(ifc_scope_labels ifc_tag_clearances ifc_principal_facts ifc_scope_facts ifc_scope_members ifc_receipts) do
      SalixStore.Repo.query!("DELETE FROM #{table}")
    end

    previous_backend = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, S3.Fake)
    if Process.whereis(S3.Fake), do: S3.Fake.reset(), else: start_supervised!(S3.Fake)

    on_exit(fn ->
      if is_nil(previous_backend),
        do: Application.delete_env(:salix_store, :s3_backend),
        else: Application.put_env(:salix_store, :s3_backend, previous_backend)
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
    test "reports off for a Group that never opted in", %{tenant: tenant, group: group} do
      assert {:ok, overview} = Admin.overview(tenant, group)
      assert overview["mode"] == "off"
      assert overview["modes"] == ~w(off audit enforce)
    end

    test "reports the Group's own mode", %{tenant: tenant} do
      group = group(tenant, %{"mode" => "enforce"})
      assert {:ok, %{"mode" => "enforce"}} = Admin.overview(tenant, group)
    end

    test "a mode nobody recognizes reads as off rather than as itself", %{tenant: tenant} do
      group = group(tenant, %{"mode" => "strict"})
      assert {:ok, %{"mode" => "off"}} = Admin.overview(tenant, group)
    end

    test "reports the language the runtime writes its own sentences in", %{
      tenant: tenant,
      group: group
    } do
      # Chinese unless the Group says otherwise, which is what every existing
      # workspace already reads.
      assert {:ok, %{"language" => "zh", "languages" => ~w(zh en)}} =
               Admin.overview(tenant, group)

      english = group(tenant, %{"mode" => "enforce", "language" => "en"})
      assert {:ok, %{"language" => "en"}} = Admin.overview(tenant, english)

      # And a language nobody composes sentences in reads as the default.
      unknown = group(tenant, %{"mode" => "enforce", "language" => "de"})
      assert {:ok, %{"language" => "zh"}} = Admin.overview(tenant, unknown)
    end

    test "an unknown Group is not found", %{tenant: tenant} do
      assert {:error, _reason} = Admin.overview(tenant, "grp_absent")
      assert {:error, _reason} = Admin.overview(tenant, "")
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

    test "refuses a tag the codec could not round-trip", %{tenant: tenant, group: group} do
      # `|` is the wire grammar's separator, so a tag containing it would decode
      # as a different atom later. Refuse where a person can still see why.
      assert {:error, :invalid_tag} =
               Admin.put_scope_label(tenant, group, @connect, "C1", %{"tags" => ["a|b"]})

      assert {:error, :invalid_tag} =
               Admin.put_scope_label(tenant, group, @connect, "C1", %{"tags" => [" "]})

      assert {:ok, []} = Store.list_scope_labels(tenant, group, @connect)
    end

    test "refuses an audience nobody implements", %{tenant: tenant, group: group} do
      assert {:error, :invalid_audience_mode} =
               Admin.put_scope_label(tenant, group, @connect, "C1", %{
                 "audience_mode" => "everyone"
               })
    end

    test "a reset returns the conversation to its defaults", %{tenant: tenant, group: group} do
      :ok = Admin.put_scope_label(tenant, group, @connect, "C1", %{"tags" => ["counsel"]})
      assert :ok = Admin.delete_scope_label(tenant, group, @connect, "C1")
      assert {:ok, []} = Store.list_scope_labels(tenant, group, @connect)
    end
  end

  describe "the conversation table" do
    test "shows observed and classified as different facts", %{tenant: tenant, group: group} do
      # Seen but never classified.
      Store.observe_scope(tenant, group, @connect, "C_SEEN", %{kind: "room"})
      # Classified before anything was ever seen in it — a real state.
      :ok = Admin.put_scope_label(tenant, group, @connect, "C_UNSEEN", %{"tags" => ["counsel"]})

      # No connect record exists in this fixture, so the overview has nothing to
      # attribute rows to. The merge itself is what matters, and both halves are
      # readable from the store: one seen and unclassified, one classified and
      # never seen.
      assert {:ok, %{"connects" => []}} = Admin.overview(tenant, group)
      assert {:ok, [%{"scope_id" => "C_SEEN"}]} = Store.list_scope_facts(tenant, group, @connect)

      assert {:ok, [%{"scope_id" => "C_UNSEEN", "tags" => ["counsel"]}]} =
               Store.list_scope_labels(tenant, group, @connect)
    end
  end

  describe "bounds" do
    test "each list returns at most the dashboard rows and flags a longer one", %{
      tenant: tenant,
      group: group
    } do
      {:ok, _} =
        SalixStore.CasRecord.create(Keys.ctl_im_connect(group, @connect), %{
          "tenant_id" => tenant,
          "group_id" => group,
          "connect_id" => @connect,
          "provider" => "slack",
          "name" => "Acme"
        })

      rows = Store.dashboard_rows()
      for n <- 1..rows, do: Store.observe_placement(tenant, group, @connect, "U#{n}", "internal")

      assert {:ok, %{"connects" => [%{"truncated" => false, "principals" => principals}]}} =
               Admin.overview(tenant, group)

      assert length(principals) == rows
      Store.observe_placement(tenant, group, @connect, "U#{rows + 1}", "internal")

      assert {:ok, %{"connects" => [%{"truncated" => true, "principals" => principals}]}} =
               Admin.overview(tenant, group)

      assert length(principals) == rows
    end
  end

  describe "the conversation window" do
    test "shows only complete rows when facts and labels both run past the bound", %{
      tenant: tenant,
      group: group
    } do
      connect_record(tenant, group)
      id = &("C" <> String.pad_leading(to_string(&1), 4, "0"))
      observed = MapSet.new(1..210, id)

      for scope <- observed,
          do: Store.observe_scope(tenant, group, @connect, scope, %{kind: "room"})

      # Classified and seen inside the window, classified but never seen inside
      # it, seen past the facts' cut, and enough never-seen labels after all of
      # them that the labels' own cut lies further still.
      labelled = ["C0150", "C0050X", "C0205"] ++ Enum.map(1..210, &"Z#{&1 + 100}")
      for scope <- labelled, do: label(tenant, group, scope)

      scopes = complete_scopes(tenant, group, observed, labelled)
      assert length(scopes) == Store.dashboard_rows()
      assert Enum.map(scopes, & &1["scope_id"]) == Enum.sort(Enum.map(scopes, & &1["scope_id"]))
      assert %{"classified" => true, "tags" => ["counsel"]} = scope(scopes, "C0150")
      assert %{"classified" => true, "observed_at" => nil} = scope(scopes, "C0050X")
      assert %{"classified" => false} = scope(scopes, "C0001")
      refute scope(scopes, "C0205")

      # Labels that sort first move the labels' cut before every fact.
      before = Enum.map(1..210, &"B#{&1 + 100}")
      for scope <- before, do: label(tenant, group, scope)
      scopes = complete_scopes(tenant, group, observed, labelled ++ before)
      assert length(scopes) == Store.dashboard_rows()
      assert Enum.all?(scopes, &String.starts_with?(&1["scope_id"], "B"))
    end
  end

  defp connect_record(tenant, group) do
    {:ok, _} =
      SalixStore.CasRecord.create(Keys.ctl_im_connect(group, @connect), %{
        "tenant_id" => tenant,
        "group_id" => group,
        "connect_id" => @connect,
        "provider" => "slack",
        "name" => "Acme"
      })
  end

  defp label(tenant, group, scope),
    do: :ok = Admin.put_scope_label(tenant, group, @connect, scope, %{"tags" => ["counsel"]})

  defp scope(scopes, id), do: Enum.find(scopes, &(&1["scope_id"] == id))

  # Every shown row tells the truth about both halves: classified exactly when
  # labelled, and observed exactly when seen.
  defp complete_scopes(tenant, group, observed, labelled) do
    assert {:ok, %{"connects" => [%{"truncated" => true, "scopes" => scopes}]}} =
             Admin.overview(tenant, group)

    for row <- scopes do
      assert row["classified"] == row["scope_id"] in labelled, row["scope_id"]
      assert not is_nil(row["observed_at"]) == MapSet.member?(observed, row["scope_id"])
    end

    scopes
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

    test "need both a tag and a person", %{tenant: tenant, group: group} do
      assert {:error, :invalid_tag} = Admin.put_tag_clearance(tenant, group, @connect, "", "U01")

      assert {:error, :invalid_principal} =
               Admin.put_tag_clearance(tenant, group, @connect, "counsel", " ")
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

    test "refuse a placement that is neither", %{tenant: tenant, group: group} do
      assert {:error, :invalid_placement} =
               Admin.put_placement_override(tenant, group, @connect, "U01", "contractor")
    end
  end
end
