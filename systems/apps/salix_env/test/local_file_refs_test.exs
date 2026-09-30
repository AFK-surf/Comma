defmodule SalixEnv.LocalFileRefsTest do
  use ExUnit.Case, async: false

  alias SalixEnv.{LocalFileRefs, Registry}
  alias SalixStore.{Ids, Repo, S3}

  setup do
    Repo.query!("TRUNCATE local_file_refs")

    previous = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:salix_store, :s3_backend, previous),
        else: Application.delete_env(:salix_store, :s3_backend)
    end)

    tenant_id = Ids.new_tenant_id()
    group_id = Ids.new_group_id(tenant_id)
    device_id = Ids.new_device_id()
    owner_user_id = "user-#{System.unique_integer([:positive])}"

    assert {:ok, _transport_id, device} =
             Registry.connect(
               to_string(node()),
               %{
                 "tenant_id" => tenant_id,
                 "group_id" => group_id,
                 "device_id" => device_id,
                 "connector_id" => "connector-local-file-test",
                 "owner_user_id" => owner_user_id,
                 "capabilities" => %{
                   "local_file_import_v1" => true,
                   "local_file_index_version" => 2
                 }
               },
               connection_generation: 7,
               transport_id: "transport-local-file-test"
             )

    {:ok,
     tenant_id: tenant_id,
     group_id: group_id,
     device_id: device_id,
     owner_user_id: owner_user_id,
     connector_run_id: device["connector_run_id"],
     generation: device["connection_generation"]}
  end

  test "registration records routing only and binds idempotently to one exact message", ctx do
    ref = local_ref()

    assert {:ok, route} = register(ctx, ref)
    assert route["state"] == "registered"
    refute Map.has_key?(route, "path")
    refute Map.has_key?(route, "connector_run_id")
    refute Map.has_key?(route, "connection_generation")

    refute Enum.any?(Map.keys(S3.Fake.dump()), &String.starts_with?(&1, "ctl/local_file_refs/"))

    message = message(ctx.owner_user_id, ref)
    assert :ok = LocalFileRefs.bind_message(ctx.group_id, message["conversation_id"], message)
    assert :ok = LocalFileRefs.bind_message(ctx.group_id, message["conversation_id"], message)

    assert {:ok, resolved} =
             LocalFileRefs.resolve_committed(
               ctx.group_id,
               message["conversation_id"],
               message,
               ref
             )

    assert resolved == %{
             "local_file_ref" => ref,
             "owner_user_id" => ctx.owner_user_id,
             "stable_device_id" => ctx.device_id,
             "connector_run_id" => ctx.connector_run_id,
             "connection_generation" => ctx.generation
           }
  end

  test "foreign author, wrong message, stale generation and revocation fail closed", ctx do
    ref = local_ref()
    assert {:ok, _route} = register(ctx, ref)
    message = message(ctx.owner_user_id, ref)
    conversation_id = message["conversation_id"]
    assert :ok = LocalFileRefs.bind_message(ctx.group_id, conversation_id, message)

    foreign = Map.put(message, "user_id", "another-user")

    assert {:error, :local_file_unavailable} =
             LocalFileRefs.resolve_committed(ctx.group_id, conversation_id, foreign, ref)

    wrong_message = Map.put(message, "message_id", Ids.new_message_id())

    assert {:error, :local_file_unavailable} =
             LocalFileRefs.resolve_committed(ctx.group_id, conversation_id, wrong_message, ref)

    assert {:ok, _record} = Registry.mark_disconnected(ctx.connector_run_id)

    assert {:error, :local_file_unavailable} =
             LocalFileRefs.resolve_committed(ctx.group_id, conversation_id, message, ref)

    assert :ok = LocalFileRefs.revoke(ctx.group_id, ctx.owner_user_id, ctx.device_id, ref)

    assert {:error, :local_file_unavailable} =
             LocalFileRefs.resolve_committed(ctx.group_id, conversation_id, message, ref)
  end

  test "legacy ownerless devices request secure token reconfiguration instead of owner claim",
       ctx do
    device_id = Ids.new_device_id()

    assert {:ok, _transport_id, _device} =
             Registry.connect(
               to_string(node()),
               %{
                 "tenant_id" => ctx.tenant_id,
                 "group_id" => ctx.group_id,
                 "device_id" => device_id,
                 "connector_id" => "connector-ownerless-legacy",
                 "capabilities" => %{"local_file_import_v1" => true}
               },
               connection_generation: 1,
               transport_id: "transport-ownerless-legacy"
             )

    assert {:error, :connector_owner_upgrade_required} =
             LocalFileRefs.register(
               ctx.tenant_id,
               ctx.group_id,
               ctx.owner_user_id,
               device_id,
               local_ref()
             )

    assert {:ok, ownerless} = Registry.get_device(ctx.tenant_id, ctx.group_id, device_id)
    refute Map.has_key?(ownerless, "owner_user_id")
    refute get_in(ownerless, ["meta", "owner_user_id"])
  end

  test "legacy registration stays compatible while V2 registration binds the exact current run",
       ctx do
    assert {:ok, _record} = Registry.mark_disconnected(ctx.connector_run_id)

    disconnected_v2_ref = local_ref()

    assert {:error, :local_file_unavailable} =
             register_v2(ctx, disconnected_v2_ref, ctx.connector_run_id)

    assert {:error, :not_found} = SalixStore.LocalFileRefs.get(disconnected_v2_ref)

    legacy_ref = local_ref()

    assert {:ok, %{"local_file_ref" => ^legacy_ref}} = register(ctx, legacy_ref)

    assert {:ok, _transport_id, replacement} =
             Registry.connect(
               to_string(node()),
               %{
                 "tenant_id" => ctx.tenant_id,
                 "group_id" => ctx.group_id,
                 "device_id" => ctx.device_id,
                 "connector_id" => "connector-local-file-replacement",
                 "owner_user_id" => ctx.owner_user_id
               },
               connection_generation: ctx.generation + 1,
               transport_id: "transport-local-file-replacement"
             )

    replacement_run_id = replacement["connector_run_id"]
    refute replacement_run_id == ctx.connector_run_id

    # Registry.connect intentionally merges the previous metadata. This is the
    # production ordering in which the new socket can temporarily expose the
    # old run's V2 capability while Main still observes the old private status.
    assert get_in(replacement, ["meta", "capabilities", "local_file_index_version"]) == 2

    stale_status_ref = local_ref()

    assert {:error, :local_file_unavailable} =
             register_v2(ctx, stale_status_ref, ctx.connector_run_id)

    assert {:error, :not_found} = SalixStore.LocalFileRefs.get(stale_status_ref)

    assert {:ok, _legacy_reader} =
             Registry.update_meta(replacement_run_id, fn meta ->
               Map.put(meta, "capabilities", %{"local_file_import_v1" => true})
             end)

    current_status_ref = local_ref()

    assert {:error, :local_file_unavailable} =
             register_v2(ctx, current_status_ref, replacement_run_id)

    assert {:error, :not_found} = SalixStore.LocalFileRefs.get(current_status_ref)

    assert {:ok, _v2_reader} =
             Registry.update_meta(replacement_run_id, fn meta ->
               Map.put(meta, "capabilities", %{
                 "local_file_import_v1" => true,
                 "local_file_index_version" => 2
               })
             end)

    assert {:ok, %{"local_file_ref" => ^current_status_ref}} =
             register_v2(ctx, current_status_ref, replacement_run_id)
  end

  test "finish-time fence rejects revoke and connector replacement after admission", ctx do
    ref = local_ref()
    assert {:ok, _route} = register(ctx, ref)
    message = message(ctx.owner_user_id, ref)
    conversation_id = message["conversation_id"]
    assert :ok = LocalFileRefs.bind_message(ctx.group_id, conversation_id, message)

    assert {:ok, admitted} =
             LocalFileRefs.resolve_committed(ctx.group_id, conversation_id, message, ref)

    assert :ok =
             LocalFileRefs.refence_committed(
               ctx.group_id,
               conversation_id,
               message,
               ref,
               admitted
             )

    assert :ok = LocalFileRefs.revoke(ctx.group_id, ctx.owner_user_id, ctx.device_id, ref)

    assert {:error, :local_file_unavailable} =
             LocalFileRefs.refence_committed(
               ctx.group_id,
               conversation_id,
               message,
               ref,
               admitted
             )

    replacement_ref = local_ref()
    assert {:ok, _route} = register(ctx, replacement_ref)
    replacement_message = message(ctx.owner_user_id, replacement_ref)
    replacement_conversation_id = replacement_message["conversation_id"]

    assert :ok =
             LocalFileRefs.bind_message(
               ctx.group_id,
               replacement_conversation_id,
               replacement_message
             )

    assert {:ok, replacement_admitted} =
             LocalFileRefs.resolve_committed(
               ctx.group_id,
               replacement_conversation_id,
               replacement_message,
               replacement_ref
             )

    assert {:ok, _record} = Registry.mark_disconnected(ctx.connector_run_id)

    assert {:ok, _transport_id, replacement_device} =
             Registry.connect(
               to_string(node()),
               %{
                 "tenant_id" => ctx.tenant_id,
                 "group_id" => ctx.group_id,
                 "device_id" => ctx.device_id,
                 "connector_id" => "connector-local-file-test",
                 "owner_user_id" => ctx.owner_user_id,
                 "capabilities" => %{
                   "local_file_import_v1" => true,
                   "local_file_index_version" => 2
                 }
               },
               connection_generation: ctx.generation + 1,
               transport_id: "transport-local-file-replacement"
             )

    refute replacement_device["connector_run_id"] == replacement_admitted["connector_run_id"]

    assert {:error, :local_file_unavailable} =
             LocalFileRefs.refence_committed(
               ctx.group_id,
               replacement_conversation_id,
               replacement_message,
               replacement_ref,
               replacement_admitted
             )
  end

  test "expired drafts cannot bind and one ref never rebinds to another message", ctx do
    ref = local_ref()
    assert {:ok, _route} = register(ctx, ref, now: 1, draft_ttl_ms: 1)
    message = message(ctx.owner_user_id, ref)

    assert {:error, :local_file_unavailable} =
             LocalFileRefs.bind_message(ctx.group_id, message["conversation_id"], message)

    fresh = local_ref()
    assert {:ok, _route} = register(ctx, fresh)
    first = message(ctx.owner_user_id, fresh)
    assert :ok = LocalFileRefs.bind_message(ctx.group_id, first["conversation_id"], first)

    second = message(ctx.owner_user_id, fresh)

    assert {:error, :local_file_ref_conflict} =
             LocalFileRefs.bind_message(ctx.group_id, second["conversation_id"], second)
  end

  test "bound routes expire at their seven-day retention deadline", ctx do
    ref = local_ref()
    assert {:ok, _route} = register(ctx, ref)
    message = message(ctx.owner_user_id, ref)
    conversation_id = message["conversation_id"]
    assert :ok = LocalFileRefs.bind_message(ctx.group_id, conversation_id, message)

    assert {:ok, %{"expires_at" => expires_at, "state" => "bound"}} =
             SalixStore.LocalFileRefs.get(ref)

    assert {:ok, _route} =
             LocalFileRefs.resolve_committed(ctx.group_id, conversation_id, message, ref,
               now: expires_at - 1
             )

    assert {:error, :local_file_unavailable} =
             LocalFileRefs.resolve_committed(ctx.group_id, conversation_id, message, ref,
               now: expires_at
             )
  end

  test "concurrent route registration settles idempotently without rebinding", ctx do
    ref = local_ref()

    results =
      1..8
      |> Enum.map(fn _ -> Task.async(fn -> register(ctx, ref) end) end)
      |> Task.await_many()

    assert Enum.all?(results, &match?({:ok, %{"local_file_ref" => ^ref}}, &1))

    other_device_id = Ids.new_device_id()

    assert {:ok, _transport_id, _device} =
             Registry.connect(
               to_string(node()),
               %{
                 "tenant_id" => ctx.tenant_id,
                 "group_id" => ctx.group_id,
                 "device_id" => other_device_id,
                 "connector_id" => "connector-local-file-other",
                 "owner_user_id" => ctx.owner_user_id,
                 "capabilities" => %{
                   "local_file_import_v1" => true,
                   "local_file_index_version" => 2
                 }
               },
               connection_generation: 1,
               transport_id: "transport-local-file-other"
             )

    assert {:error, :local_file_ref_conflict} =
             LocalFileRefs.register(
               ctx.tenant_id,
               ctx.group_id,
               ctx.owner_user_id,
               other_device_id,
               ref
             )
  end

  test "bounded cleanup retires expired routes and permanently rejects ref reuse", ctx do
    now = System.system_time(:millisecond)
    registered_ref = local_ref()
    bound_ref = local_ref()
    live_ref = local_ref()

    assert {:ok, _} = register(ctx, registered_ref, now: now - 10, draft_ttl_ms: 1)
    assert {:ok, _} = register(ctx, bound_ref, now: now - 10, draft_ttl_ms: 1_000)
    assert {:ok, _} = register(ctx, live_ref, now: now, draft_ttl_ms: 1_000)

    bound_message = message(ctx.owner_user_id, bound_ref)

    assert :ok =
             LocalFileRefs.bind_message(
               ctx.group_id,
               bound_message["conversation_id"],
               bound_message
             )

    # Force the bound retention deadline to make the cleanup boundary deterministic.
    Repo.query!("UPDATE local_file_refs SET expires_at = $1 WHERE ref_digest = $2", [
      DateTime.from_unix!((now - 1) * 1_000, :microsecond),
      SalixStore.LocalFileRefs.ref_digest(bound_ref)
    ])

    assert {:ok, 2} = LocalFileRefs.cleanup_expired(now, limit: 2)

    assert {:ok, %{"state" => "retired"}} =
             SalixStore.LocalFileRefs.get(registered_ref)

    assert {:ok, %{"state" => "retired"}} = SalixStore.LocalFileRefs.get(bound_ref)
    assert {:ok, %{"state" => "registered"}} = SalixStore.LocalFileRefs.get(live_ref)

    assert {:error, :local_file_ref_conflict} =
             register(ctx, registered_ref, now: now + 1, draft_ttl_ms: 1_000)

    assert {:error, :local_file_ref_conflict} =
             register(ctx, bound_ref, now: now + 1, draft_ttl_ms: 1_000)
  end

  defp register(ctx, ref, opts \\ []) do
    LocalFileRefs.register(
      ctx.tenant_id,
      ctx.group_id,
      ctx.owner_user_id,
      ctx.device_id,
      ref,
      opts
    )
  end

  defp register_v2(ctx, ref, connector_run_id, opts \\ []) do
    register(
      ctx,
      ref,
      Keyword.merge(opts,
        connector_run_id: connector_run_id,
        local_file_index_version: 2
      )
    )
  end

  defp message(owner_user_id, ref) do
    %{
      "actor_type" => "user",
      "user_id" => owner_user_id,
      "message_id" => Ids.new_message_id(),
      "conversation_id" => Ids.new_conversation_id(),
      "content" => [
        %{"type" => "text", "text" => "review"},
        %{"type" => "local_file", "local_file_ref" => ref}
      ]
    }
  end

  defp local_ref,
    do: "lfi1_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
end
