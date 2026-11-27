defmodule SalixIM.Provider.LarkSuite.AddresseeTest do
  use ExUnit.Case, async: true

  alias SalixIM.Provider.LarkSuite.Addressee

  @connect %{"bot_open_id" => "ou_bot"}

  defp mention(key, id, name) do
    %{"key" => key, "id" => id, "name" => name}
  end

  defp group_message(mentions),
    do: %{"chat_type" => "group", "mentions" => mentions}

  test "classifies self, mixed, other, and none" do
    self_m = mention("@_user_1", %{"open_id" => "ou_bot"}, "SelfBot")
    peer_m = mention("@_user_2", %{"open_id" => "ou_peer"}, "PeerBot")

    assert Addressee.for_message(@connect, group_message([self_m])) == "self"
    assert Addressee.for_message(@connect, group_message([self_m, peer_m])) == "mixed"
    assert Addressee.for_message(@connect, group_message([peer_m])) == "other"
    assert Addressee.for_message(@connect, group_message([])) == "none"

    assert Addressee.mentions_self?(@connect, group_message([self_m]))
    assert Addressee.mentions_self?(@connect, group_message([self_m, peer_m]))
    refute Addressee.mentions_self?(@connect, group_message([peer_m]))
    refute Addressee.mentions_self?(@connect, group_message([]))

    assert Addressee.directed_elsewhere?(@connect, group_message([peer_m]))
    refute Addressee.directed_elsewhere?(@connect, group_message([self_m]))
    refute Addressee.directed_elsewhere?(@connect, group_message([self_m, peer_m]))
    refute Addressee.directed_elsewhere?(@connect, group_message([]))

    refute Addressee.directed_elsewhere?(@connect, %{"chat_type" => "p2p", "mentions" => [peer_m]})
  end

  test "ignores @all broadcast mentions so they never count as other" do
    broadcasts = [
      mention("@_all", %{"open_id" => "all"}, "所有人"),
      mention(" @_ALL ", %{"open_id" => "ou_ignored"}, "All"),
      mention("@_user_1", %{"open_id" => " ALL "}, "All"),
      mention("@_user_2", %{"user_id" => "all"}, "All")
    ]

    for broadcast <- broadcasts do
      msg = group_message([broadcast])
      assert Addressee.for_message(@connect, msg) == "none"
      refute Addressee.directed_elsewhere?(@connect, msg)
      refute Addressee.mentions_self?(@connect, msg)
    end

    self_m = mention("@_user_1", %{"open_id" => "ou_bot"}, "SelfBot")
    mixed_with_all = group_message([self_m, hd(broadcasts)])
    assert Addressee.for_message(@connect, mixed_with_all) == "self"
    assert Addressee.mentions_self?(@connect, mixed_with_all)
    refute Addressee.directed_elsewhere?(@connect, mixed_with_all)
  end

  test "falls back to user_id and union_id and handles missing bot_open_id safely" do
    user_id_only = mention("@_user_1", %{"user_id" => "u_other"}, "Other")
    union_id_only = mention("@_user_2", %{"union_id" => "on_other"}, "Union")

    assert Addressee.for_message(@connect, group_message([user_id_only])) == "other"
    assert Addressee.for_message(@connect, group_message([union_id_only])) == "other"

    blank_connect = %{"bot_open_id" => ""}
    self_m = mention("@_user_1", %{"open_id" => "ou_bot"}, "SelfBot")

    refute Addressee.mentions_self?(blank_connect, group_message([self_m]))
    assert Addressee.for_message(blank_connect, group_message([])) == "none"
  end
end
