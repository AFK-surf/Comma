defmodule CommaWeb.IMNotifierTest do
  use ExUnit.Case, async: false

  setup do
    previous_notifier = Application.get_env(:salix_im, :conversation_notifier)
    previous_backend = Application.get_env(:salix_store, :s3_backend)

    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    ensure_fake_s3!()
    CommaWeb.Application.register_im_notifier()

    on_exit(fn ->
      restore_env(:salix_im, :conversation_notifier, previous_notifier)
      restore_env(:salix_store, :s3_backend, previous_backend)
    end)

    :ok
  end

  test "fans IM hints only to SalixWeb subscribers" do
    agent_id = "agent-im-notifier"
    conversation_id = SalixStore.Ids.new_conversation_id()
    message_id = SalixStore.Ids.new_message_id()

    Phoenix.PubSub.subscribe(SalixWeb.PubSub, SalixWeb.PubSubNotifier.topic(agent_id))

    notifier = Application.fetch_env!(:salix_im, :conversation_notifier)

    assert :ok =
             notifier.(agent_id, {:conversation_message_created, conversation_id, message_id})

    assert_receive {:salix_agent_event, ^agent_id,
                    {:conversation_message_created, ^conversation_id, ^message_id}}

    assert {:ok, []} = SalixStore.S3.list_all("comma/conversation_events/")
  end

  test "registration replaces a stale notifier closure" do
    dead_pid = spawn(fn -> Process.sleep(:infinity) end)
    ref = Process.monitor(dead_pid)
    Process.exit(dead_pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^dead_pid, :killed}

    Application.put_env(:salix_im, :conversation_notifier, fn agent_id, event ->
      send(dead_pid, {:stale_notifier_called, agent_id, event})
    end)

    CommaWeb.Application.register_im_notifier()

    agent_id = "agent-im-notifier-reregistered"
    conversation_id = SalixStore.Ids.new_conversation_id()
    message_id = SalixStore.Ids.new_message_id()
    Phoenix.PubSub.subscribe(SalixWeb.PubSub, SalixWeb.PubSubNotifier.topic(agent_id))

    notifier = Application.fetch_env!(:salix_im, :conversation_notifier)
    assert :ok = notifier.(agent_id, {:conversation_message_created, conversation_id, message_id})

    assert_receive {:salix_agent_event, ^agent_id,
                    {:conversation_message_created, ^conversation_id, ^message_id}}
  end

  defp ensure_fake_s3! do
    if Process.whereis(SalixStore.S3.Fake) do
      SalixStore.S3.Fake.reset()
    else
      start_supervised!(SalixStore.S3.Fake)
    end
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
