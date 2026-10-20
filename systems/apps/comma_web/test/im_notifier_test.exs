defmodule CommaWeb.IMNotifierTest do
  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle, scope: ["Elixir.CommaWeb", "Elixir.Comma"]

  setup do
    previous_notifier = SystemsRuntime.get_env(:salix_im, :conversation_notifier)
    previous_backend = SystemsRuntime.get_env(:salix_store, :s3_backend)

    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
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

    notifier = SystemsRuntime.fetch_env!(:salix_im, :conversation_notifier)

    assert :ok =
             notifier.(agent_id, {:conversation_message_created, conversation_id, message_id})

    settle_receive(
      {:salix_agent_event, ^agent_id,
       {:conversation_message_created, ^conversation_id, ^message_id}}
    )

    assert {:ok, []} = SalixStore.S3.list_all("comma/conversation_events/")
  end

  defp ensure_fake_s3! do
    if SystemsRuntime.Proc.whereis(SalixStore.S3.Fake) do
      SalixStore.S3.Fake.reset()
    else
      start_supervised!(SalixStore.S3.Fake)
    end
  end

  defp restore_env(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore_env(app, key, value), do: SystemsRuntime.put_env(app, key, value)
end
