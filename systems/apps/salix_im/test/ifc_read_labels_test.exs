defmodule SalixIM.IFCReadLabelsTest do
  @moduledoc """
  The audience a read returned
  (`docs/verification.md` §3.3, §15).

  A read is never filtered, so what makes a search safe to answer from is that
  its hits are labelled by where they came from. These tests are about that
  labelling and nothing else: given the projection's view of two channels, what
  does a result carry, and what does an effect citing one hit inherit.

  Every test uses its own group id, because the mode is cached for half a
  minute per `(tenant, group)` and these Groups deliberately differ in it.
  """

  use ExUnit.Case, async: false

  alias SalixIM.IFC.ReadLabels
  alias SalixStore.{Ids, Keys, S3}
  alias SalixStore.IFC, as: Store

  @connect "cnx_im_read_labels"

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
    {:ok, tenant: tenant}
  end

  # A real Group record, because the mode is read through the control store the
  # way the running system reads it.
  defp group(tenant, mode) do
    group_id = Ids.new_group_id(tenant)

    {:ok, _result} =
      S3.put(
        Keys.ctl_group(group_id),
        Jason.encode!(%{
          "group_id" => group_id,
          "tenant_id" => tenant,
          "router_conversation_id" => Ids.new_conversation_id(),
          "ifc" => %{"mode" => mode}
        })
      )

    group_id
  end

  defp connect(tenant, group_id),
    do: %{"tenant_id" => tenant, "group_id" => group_id, "connect_id" => @connect}

  # One public channel and one private room, which is the shape every
  # interesting case here needs.
  defp observe(tenant, group_id) do
    Store.observe_scope(tenant, group_id, @connect, "C_PUB", %{kind: "public"})
    Store.observe_scope(tenant, group_id, @connect, "C_LEGAL", %{kind: "room"})
    :ok
  end

  defp space, do: "space|#{@connect}"
  defp legal, do: "scope|#{@connect}|C_LEGAL"

  describe "a read bounded to one scope" do
    test "carries that scope's audience", %{tenant: tenant} do
      group_id = group(tenant, "enforce")
      observe(tenant, group_id)

      assert %{"label" => [legal_atom]} =
               ReadLabels.for_scope(connect(tenant, group_id), "C_LEGAL")

      assert legal_atom == legal()
    end

    test "a public channel reads as the whole space, as ingress labels it too", %{tenant: tenant} do
      group_id = group(tenant, "enforce")
      observe(tenant, group_id)

      assert %{"label" => [space_atom]} = ReadLabels.for_scope(connect(tenant, group_id), "C_PUB")
      assert space_atom == space()
    end

    test "carries the operator's classification tags with it", %{tenant: tenant} do
      group_id = group(tenant, "enforce")
      observe(tenant, group_id)
      Store.put_scope_label(tenant, group_id, @connect, "C_LEGAL", %{tags: ["counsel"]})

      assert %{"label" => label} = ReadLabels.for_scope(connect(tenant, group_id), "C_LEGAL")
      assert Enum.sort(label) == Enum.sort([legal(), "tag|counsel"])
    end

    test "a scope it cannot name is not labelled at all", %{tenant: tenant} do
      group_id = group(tenant, "enforce")
      assert ReadLabels.for_scope(connect(tenant, group_id), "") == nil
      assert ReadLabels.for_scope(connect(tenant, group_id), nil) == nil
    end
  end

  describe "a search across scopes" do
    test "labels each hit by the channel it came from", %{tenant: tenant} do
      group_id = group(tenant, "enforce")
      observe(tenant, group_id)

      messages = [
        %{"channel" => "C_PUB", "ts" => "1"},
        %{"channel" => "C_LEGAL", "ts" => "2"},
        %{"channel" => "C_PUB", "ts" => "3"}
      ]

      assert %{"label" => label, "items" => items} =
               ReadLabels.for_messages(connect(tenant, group_id), messages)

      assert [
               %{"index" => 0, "label" => [first]},
               %{"index" => 1, "label" => [legal_atom]},
               %{"index" => 2, "label" => [third]}
             ] = items

      assert first == space()
      assert legal_atom == legal()
      # The same channel twice is the same label, resolved once.
      assert third == space()

      # The result as a whole is the join of its hits, so citing the page is as
      # restrictive as citing its most private row.
      assert Enum.sort(label) == Enum.sort([space(), legal()])
    end

    test "a hit whose channel is unknown fails closed rather than loosening the join", %{
      tenant: tenant
    } do
      group_id = group(tenant, "enforce")
      observe(tenant, group_id)

      messages = [%{"channel" => "C_PUB", "ts" => "1"}, %{"ts" => "2"}]

      assert %{"label" => label, "items" => items} =
               ReadLabels.for_messages(connect(tenant, group_id), messages)

      assert [%{"index" => 0}, %{"index" => 1, "label" => ["agent_private"]}] = items
      assert "agent_private" in label
    end

    test "an empty page is labelled, and reads as private rather than public", %{tenant: tenant} do
      group_id = group(tenant, "enforce")

      assert %{"label" => ["agent_private"], "items" => []} =
               ReadLabels.for_messages(connect(tenant, group_id), [])
    end
  end

  describe "one thing that lives in several scopes" do
    test "carries the join of all of them, which is the restrictive direction", %{tenant: tenant} do
      group_id = group(tenant, "enforce")
      observe(tenant, group_id)

      assert %{"label" => label} =
               ReadLabels.for_scopes(connect(tenant, group_id), ["C_PUB", "C_LEGAL"])

      # Not `space` alone: a file shared into a public channel and a private one
      # may only go where both may go.
      assert Enum.sort(label) == Enum.sort([space(), legal()])
      refute Map.has_key?(ReadLabels.for_scopes(connect(tenant, group_id), ["C_PUB"]), "items")
    end

    test "one scope is exactly that scope", %{tenant: tenant} do
      group_id = group(tenant, "enforce")
      observe(tenant, group_id)

      assert ReadLabels.for_scopes(connect(tenant, group_id), ["C_LEGAL"]) ==
               ReadLabels.for_scope(connect(tenant, group_id), "C_LEGAL")

      # The same place named twice is the same audience, not a stricter one.
      assert ReadLabels.for_scopes(connect(tenant, group_id), ["C_LEGAL", "C_LEGAL"]) ==
               ReadLabels.for_scope(connect(tenant, group_id), "C_LEGAL")
    end

    test "a place nobody has observed still narrows the join", %{tenant: tenant} do
      group_id = group(tenant, "enforce")
      observe(tenant, group_id)

      assert %{"label" => label} =
               ReadLabels.for_scopes(connect(tenant, group_id), ["C_PUB", "C_ABSENT"])

      # An unobserved channel is a scope of its own, not the space, so the file
      # does not inherit the public channel's reach. Whether anyone may read it
      # is then a membership question the kernel answers, and cannot: an
      # unobserved scope has no members, so the flow is denied rather than
      # guessed.
      assert Enum.sort(label) ==
               Enum.sort([space(), "scope|#{@connect}|C_ABSENT"])
    end

    test "nowhere at all is not labelled, because nothing was established", %{tenant: tenant} do
      group_id = group(tenant, "enforce")
      assert ReadLabels.for_scopes(connect(tenant, group_id), []) == nil
      assert ReadLabels.for_scopes(connect(tenant, group_id), ["", nil]) == nil
    end
  end

  describe "a Group that has not opted in" do
    test "is not labelled, and never reaches the projection", %{tenant: tenant} do
      group_id = group(tenant, "off")
      observe(tenant, group_id)

      assert ReadLabels.for_scope(connect(tenant, group_id), "C_LEGAL") == nil

      assert ReadLabels.for_messages(connect(tenant, group_id), [%{"channel" => "C_LEGAL"}]) ==
               nil
    end

    test "an unknown Group is off too", %{tenant: tenant} do
      connect = %{"tenant_id" => tenant, "group_id" => "grp_absent", "connect_id" => @connect}
      assert ReadLabels.for_scope(connect, "C_LEGAL") == nil
    end

    test "a connect with nothing to scope by is off" do
      assert ReadLabels.for_scope(%{}, "C_LEGAL") == nil
      assert ReadLabels.for_messages(%{}, [%{"channel" => "C_LEGAL"}]) == nil
      assert ReadLabels.for_scopes(%{}, ["C_LEGAL"]) == nil
    end
  end

  describe "a provider whose hits name their own scope" do
    test "labels each hit by the key that provider uses", %{tenant: tenant} do
      group_id = group(tenant, "enforce")
      observe(tenant, group_id)

      # A Feishu page names its chat in `chat_id`, not `channel`. A thread page
      # is addressed by thread id and never says which chat it is in, so the
      # audience is read off the messages rather than off the argument.
      messages = [%{"chat_id" => "C_LEGAL"}, %{"chat_id" => "C_PUB"}]

      assert %{"label" => label, "items" => items} =
               ReadLabels.for_messages(connect(tenant, group_id), messages, "chat_id")

      assert [%{"index" => 0, "label" => [legal_atom]}, %{"index" => 1, "label" => [space_atom]}] =
               items

      assert legal_atom == legal()
      assert space_atom == space()
      assert Enum.sort(label) == Enum.sort([space(), legal()])
    end
  end
end
