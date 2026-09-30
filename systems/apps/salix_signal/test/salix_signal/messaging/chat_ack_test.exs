defmodule SalixSignal.Messaging.ChatAckTest do
  # The receive pipeline on the real chat socket client (CRS-01 §10, CRS-07
  # §5.3): an envelope pushed over the socket is answered only after its
  # outcome is committed, and a fenced (stale) owner leaves it unanswered so
  # the service keeps it queued.
  use ExUnit.Case, async: true

  # Upper bounds on a loaded machine, not expectations: a TLS connect and
  # upgrade (the chat client's own connect timeout is 10 s), and any other
  # wait for a message or a task.
  @connect_ms 30_000
  @wait_ms 30_000

  alias SalixSignal.Messaging.{Inbound, Pipeline}
  alias SalixSignal.Service.{Chat, Credentials}
  alias SalixSignal.Test.{FakeChat, MemoryStore, MockService, SignalAccount}
  alias SalixSignalProto.Service.Frame

  @alice "00000000-0000-4000-8000-000000000021"
  @bob "00000000-0000-4000-8000-000000000022"

  setup_all do
    %{chain: FakeChat.chain()}
  end

  setup %{chain: chain} do
    {:ok, upgrades} = Agent.start_link(fn -> [] end)
    server = start_supervised!({Bandit, FakeChat.bandit_options(self(), chain, upgrades)})

    chat =
      start_supervised!(
        {Chat,
         owner: self(),
         host: "localhost",
         port: FakeChat.port(server),
         roots: [chain.root],
         credentials: Credentials.device(@bob, 1, "device-password"),
         backoff: [base_ms: 10, max_ms: 40]}
      )

    assert_receive {:signal_chat, ^chat, {:connected, _info}}, @connect_ms
    assert_receive {:fake_chat, :connected, socket}, @connect_ms

    {:ok, service} = MockService.start_link()

    %{
      chat: chat,
      socket: socket,
      alice: SignalAccount.new(service, @alice),
      bob: SignalAccount.new(service, @bob)
    }
  end

  # Moves the envelopes the mock service queued for Bob onto the socket.
  defp push_queued(%{socket: socket, bob: bob}, first_id) do
    bob.service
    |> MockService.queued(@bob, 1)
    |> Enum.with_index(first_id)
    |> Enum.map(fn {{_guid, bytes}, id} ->
      request = %Frame.Request{
        verb: "PUT",
        path: "/api/v1/message",
        id: id,
        body: bytes,
        headers: [{"X-Signal-Timestamp", "1758790000500"}]
      }

      send(socket, {:send, Frame.encode_request(request)})
      id
    end)
  end

  test "a committed envelope is acknowledged; a fenced one is not",
       %{chat: chat, socket: socket, alice: alice, bob: bob} = context do
    {{:ok, _}, alice} = SignalAccount.run(alice, &Pipeline.send_text(&1, @bob, "over the socket"))
    [id] = push_queued(context, 10)

    assert_receive {:signal_chat, ^chat, {:message, envelope, 1_758_790_000_500, token}}, @wait_ms

    {events, _pipeline} =
      Pipeline.handle_chat_message(bob.pipeline, chat, envelope, 1_758_790_000_500, token)

    assert [%Inbound{outcome: :message}] = for({:message, i} <- events, do: i)
    assert [%Inbound{outcome: :message}] = MemoryStore.inbound(bob.store)
    assert_receive {:fake_chat, :frame, ^socket, %Frame.Response{id: ^id, status: 200}}, @wait_ms

    # A newer owner took the account: nothing is committed or acknowledged.
    MockService.ack(bob.service, @bob, 1, hd(MockService.queued(bob.service, @bob, 1)) |> elem(0))
    {{:ok, _}, _alice} = SignalAccount.run(alice, &Pipeline.send_text(&1, @bob, "fenced"))
    MemoryStore.set_epoch(bob.store, 2)
    [id] = push_queued(context, 20)

    assert_receive {:signal_chat, ^chat, {:message, envelope, _ts, token}}, @wait_ms

    assert {[:fenced], _pipeline} =
             Pipeline.handle_chat_message(bob.pipeline, chat, envelope, nil, token)

    refute_receive {:fake_chat, :frame, ^socket, %Frame.Response{id: ^id}}, 200
    assert length(MemoryStore.inbound(bob.store)) == 1
  end
end
