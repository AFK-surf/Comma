defmodule SalixSignal.IMHandlerTest do
  # The product handler's view of admitted Signal content
  # (docs/messaging-voice.md): which chat a message belongs to, and which
  # kinds reach the Router as text, reactions, edits and deletes. Content is
  # built with the CRS-05 builders of SalixSignalProto.Message.Content.
  use ExUnit.Case, async: true

  alias SalixSignal.{IMHandler, IMPort}
  alias SalixSignal.Messaging.Inbound
  alias SalixSignalProto.Group.Params
  alias SalixSignalProto.Message.Content
  alias SalixSignalProto.ServiceId

  @account "00000000-0000-4000-8000-00000000a001"
  @alice "00000000-0000-4000-8000-000000000011"
  @comma "00000000-0000-4000-8000-000000000021"

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

  test "reactions, edits and deletes are distinct events" do
    {:ok, comma_bytes} = ServiceId.aci_from_string(@comma)

    assert {:ok, %{"type" => "reaction", "reaction" => reaction}} =
             normalize(
               Content.reaction(1_700_000_000_500, "👍", comma_bytes, 1_700_000_000_100),
               :data
             )

    assert reaction == %{
             "emoji" => "👍",
             "remove" => false,
             "target_author" => @comma,
             "target_timestamp" => 1_700_000_000_100
           }

    assert {:ok, %{"type" => "edit", "text" => "fixed", "target_timestamp" => 1_700_000_000_100}} =
             normalize(Content.edit(1_700_000_000_500, 1_700_000_000_100, "fixed"), :edit)

    assert {:ok, %{"type" => "delete", "target_timestamp" => 1_700_000_000_100}} =
             normalize(Content.remote_delete(1_700_000_000_500, 1_700_000_000_100), :data)
  end

  test "receipts, typing and control updates carry no Router input" do
    assert :skip = normalize(Content.receipt(:read, [1]), :receipt)
    assert :skip = normalize(Content.typing(1, :started), :typing)
    assert :skip = normalize(Content.expire_timer_update(1, 3600, 1), :data)
    assert :skip = normalize(Content.profile_key_update(1, :binary.copy(<<1>>, 32)), :data)
    assert :skip = normalize(<<0xFF, 0x01>>, :data)
  end

  test "a peer string is an ACI or a 32-byte group identifier" do
    assert {:user, @alice} = IMPort.parse_peer(String.upcase(@alice))
    assert :error = IMPort.parse_peer("group:" <> Base.url_encode64("short", padding: false))
    assert :error = IMPort.parse_peer("not-an-aci")

    assert {:error, :invalid_author} =
             IMPort.send_reaction(@account, @alice, "👍", "bad", 1, false)
  end
end
