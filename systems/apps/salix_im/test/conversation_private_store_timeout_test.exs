defmodule SalixIM.ConversationPrivateStoreTimeoutTest do
  use ExUnit.Case, async: false

  alias SalixIM.{ConversationInput, ConversationPlacement, ConversationServer, Conversations}
  alias SalixStore.{Ids, Keys}

  defmodule SlowMetaGetS3 do
    @moduledoc false
    @behaviour SalixStore.S3

    @impl true
    def get(key, opts) do
      if Application.get_env(:salix_im, :slow_private_store_meta_key) == key do
        Application.delete_env(:salix_im, :slow_private_store_meta_key)
        Process.sleep(5_100)
      end

      SalixStore.S3.Fake.get(key, opts)
    end

    @impl true
    defdelegate put(key, body, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate put_stream(key, stream, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate stream(key, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate head(key), to: SalixStore.S3.Fake

    @impl true
    defdelegate delete(key, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate list(prefix, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_create(key, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_upload_part(key, upload_id, part_number, body),
      to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_complete(key, upload_id, parts), to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_abort(key, upload_id), to: SalixStore.S3.Fake
  end

  defmodule BlockingMetaPutS3 do
    @moduledoc false
    @behaviour SalixStore.S3

    @impl true
    def put(key, body, opts) do
      if Application.get_env(:salix_im, :blocked_private_store_meta_key) == key do
        Application.delete_env(:salix_im, :blocked_private_store_meta_key)
        test_pid = Application.fetch_env!(:salix_im, :blocked_private_store_test_pid)
        send(test_pid, {:private_store_put_blocked, self()})

        receive do
          :release_private_store_put -> :ok
        after
          5_000 -> raise "private Store barrier was not released"
        end
      end

      SalixStore.S3.Fake.put(key, body, opts)
    end

    @impl true
    defdelegate get(key, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate put_stream(key, stream, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate stream(key, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate head(key), to: SalixStore.S3.Fake

    @impl true
    defdelegate delete(key, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate list(prefix, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_create(key, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_upload_part(key, upload_id, part_number, body),
      to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_complete(key, upload_id, parts), to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_abort(key, upload_id), to: SalixStore.S3.Fake
  end

  setup do
    SalixIM.TestSupport.Fleet.stop_all!()

    previous_backend = Application.get_env(:salix_store, :s3_backend)
    previous_placement = Application.get_env(:salix_im, :conversation_placement)
    previous_slow_key = Application.get_env(:salix_im, :slow_private_store_meta_key)

    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    Application.put_env(
      :salix_im,
      :conversation_placement,
      ConversationPlacement.LocalFleet
    )

    start_supervised!(SalixStore.S3.Fake)

    on_exit(fn ->
      try do
        SalixIM.TestSupport.Fleet.stop_all!()
      after
        restore(:salix_store, :s3_backend, previous_backend)
        restore(:salix_im, :conversation_placement, previous_placement)
        restore(:salix_im, :slow_private_store_meta_key, previous_slow_key)
        Application.delete_env(:salix_im, :blocked_private_store_meta_key)
        Application.delete_env(:salix_im, :blocked_private_store_test_pid)
      end
    end)

    tenant_id = SalixAgent.TestSupport.new_tenant_id()
    group_id = Ids.new_group_id(tenant_id)
    SalixAgent.TestSupport.create_control_group!(group_id, %{"name" => "Private store timeout"})

    router =
      SalixAgent.TestSupport.create_control_agent_in_group!(tenant_id, group_id, %{
        "name" => "Router",
        "role" => "router"
      })

    {:ok, _group} =
      SalixStore.CasRecord.update(SalixStore.Keys.ctl_group(group_id), fn group ->
        Map.put(group, "router_agent_id", router["agent_id"])
      end)

    {:ok, %{"conversation_id" => conversation_id}} =
      ConversationInput.create_group_conversation(group_id, %{
        "title" => "Slow private store"
      })

    {:ok, tenant_id: tenant_id, group_id: group_id, conversation_id: conversation_id}
  end

  @tag timeout: 20_000
  test "public delete tolerates storage latency within the owner command timeout", context do
    conversation_key =
      Keys.ctl_group_conversation(context.group_id, context.conversation_id)

    Application.put_env(:salix_im, :slow_private_store_meta_key, conversation_key)
    Application.put_env(:salix_store, :s3_backend, SlowMetaGetS3)

    assert :ok =
             ConversationServer.delete_group_conversation(
               context.group_id,
               context.conversation_id
             )
  end

  test "an abandoned outer caller does not cancel the owner or its private mutation", context do
    conversation_key =
      Keys.ctl_group_conversation(context.group_id, context.conversation_id)

    Application.put_env(:salix_im, :blocked_private_store_meta_key, conversation_key)
    Application.put_env(:salix_im, :blocked_private_store_test_pid, self())
    Application.put_env(:salix_store, :s3_backend, BlockingMetaPutS3)

    caller =
      Task.async(fn ->
        ConversationServer.update_group_conversation(
          context.group_id,
          context.conversation_id,
          %{"title" => "committed after caller deadline"}
        )
      end)

    assert_receive {:private_store_put_blocked, store_process}, 1_000
    assert nil == Task.yield(caller, 10)
    assert nil == Task.shutdown(caller, :brutal_kill)

    send(store_process, :release_private_store_put)

    assert eventually(fn ->
             case Conversations.get_group_conversation(
                    context.group_id,
                    context.conversation_id
                  ) do
               {:ok, %{"title" => "committed after caller deadline"}} -> true
               _ -> false
             end
           end)
  end

  @tag timeout: 45_000
  test "delete cleanup keeps the conversation owner alive while the group mutation is pending",
       context do
    assert {:ok, _pin} =
             ConversationServer.pin_conversation(
               context.group_id,
               context.conversation_id,
               context.tenant_id
             )

    assert {:ok, conversation_owner} =
             ConversationPlacement.ensure_started(context.group_id, context.conversation_id)

    assert {:ok, group_owner} =
             ConversationPlacement.ensure_group_started(context.group_id)

    conversation_owner_ref = Process.monitor(conversation_owner)
    :ok = :sys.suspend(group_owner)
    on_exit(fn -> resume_if_alive(group_owner) end)

    assert :ok =
             ConversationServer.delete_group_conversation(
               context.group_id,
               context.conversation_id
             )

    assert {:error, :not_found} =
             Conversations.get_group_conversation(
               context.group_id,
               context.conversation_id
             )

    assert eventually(fn ->
             pending_remove_pin_call?(
               group_owner,
               context.conversation_id
             )
           end)

    refute_receive {:DOWN, ^conversation_owner_ref, :process, ^conversation_owner, _reason},
                   31_000

    :ok = :sys.resume(group_owner)

    assert eventually(fn ->
             Conversations.list_conversation_pins(context.group_id, context.tenant_id) ==
               {:ok, %{"data" => [], "has_more" => false}}
           end)

    assert_receive {:DOWN, ^conversation_owner_ref, :process, ^conversation_owner, :normal}, 2_000
  end

  defp eventually(fun, retries \\ 100)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, retries) do
    if fun.() do
      true
    else
      Process.sleep(20)
      eventually(fun, retries - 1)
    end
  end

  defp pending_remove_pin_call?(group_owner, conversation_id) do
    case Process.info(group_owner, :messages) do
      {:messages, messages} ->
        Enum.any?(messages, fn
          {:"$gen_call", _from, {:remove_deleted_pin, ^conversation_id}} -> true
          _message -> false
        end)

      nil ->
        false
    end
  end

  defp resume_if_alive(pid) do
    if Process.alive?(pid) do
      :sys.resume(pid)
    end
  catch
    :exit, _reason -> :ok
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
