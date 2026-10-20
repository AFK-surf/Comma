defmodule SalixSignal.IMHandlerTest do
  # The product handler's view of admitted Signal content
  # (docs/messaging-voice.md): which chat a message belongs to, and which
  # kinds reach the Router as text, reactions, edits and deletes. Content is
  # built with the CRS-05 builders of SalixSignalProto.Message.Content.
  use SystemsClock.Case, async: true

  alias SalixSignal.{IMHandler, IMPort}
  alias SalixSignal.Messaging.Inbound
  alias SalixSignalProto.Group.Params
  alias SalixSignalProto.Message.Content
  alias SalixSignalProto.ServiceId

  @account "00000000-0000-4000-8000-00000000a001"
  @alice "00000000-0000-4000-8000-000000000011"
  defp inbound(content, kind, opts) do
    %Inbound{
      # The pipeline stores the envelope GUID as its 16 raw UUID bytes.
      guid:
        <<0x9C, 0x5B, 0x94, 0x32, 0x1F, 0x0E, 0x4A, 0x6D, 0x8B, 0x21, 0x3C, 0x77, 0x40, 0x5E,
          0x12, 0x9A>>,
      outcome: :message,
      sender: Keyword.get(opts, :sender, @alice),
      sender_device: 1,
      destination: :aci,
      timestamp: 1_700_000_000_500,
      server_timestamp: 1_700_000_000_600,
      content_kind: kind,
      content: content,
      group_id: Keyword.get(opts, :group_id)
    }
  end

  defp normalize(content, kind, opts \\ []),
    do: IMHandler.normalize(@account, 7, inbound(content, kind, opts))

  test "a private text names the sender as the chat" do
    assert {:ok, event} = normalize(Content.text(1_700_000_000_500, "hello"), :data)

    assert %{
             "account_id" => @account,
             "seq" => 7,
             "sender" => @alice,
             "timestamp" => 1_700_000_000_500,
             "chat" => %{"kind" => "user", "peer" => @alice},
             "type" => "message",
             "text" => "hello",
             "attachments" => []
           } = event

    # Router input is JSON text: the GUID is the UUID's text form.
    assert event["guid"] == "9c5b9432-1f0e-4a6d-8b21-3c77405e129a"
  end

  test "a group message names the group derived from its master key" do
    master_key = :binary.copy(<<3>>, 32)
    group_id = Params.from_master_key(master_key).group_id

    content =
      Content.text(1_700_000_000_500, "hi all", group: %{master_key: master_key, revision: 4})

    assert {:ok, %{"chat" => chat}} = normalize(content, :data)
    assert chat == %{"kind" => "group", "peer" => IMPort.group_peer(group_id)}
    assert {:group, ^group_id} = IMPort.parse_peer(chat["peer"])
  end
end
