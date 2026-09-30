defmodule CommaWeb.ChatDeviceViewTest do
  use ExUnit.Case, async: true
  alias CommaWeb.ChatDeviceView

  test "readiness expires independently of connectivity and omits account details" do
    runtime = %{
      "provider" => "codex",
      "status" => "ready",
      "version" => "1.2",
      "readiness_checked_at" => 100,
      "readiness_valid_until" => 110,
      "auth" => %{"mode" => "chatgpt", "email" => "private@example.com"}
    }

    device = %{
      "name" => "Studio",
      "status" => "connected",
      "allows_operations" => true,
      "device_runtimes" => [runtime]
    }

    result = %{
      kind: :detail,
      device: device,
      index: 1,
      observed_at: 109,
      view: %{"revision" => "123456ABCDEF", "cursor" => nil, "next_cursor" => nil}
    }

    workspace = %{"name" => "Work"}
    text = ChatDeviceView.render(result, workspace, "en").text
    assert text =~ "ready when read"
    assert text =~ "Valid until"
    refute text =~ "private@example.com"

    assert ChatDeviceView.render(%{result | observed_at: 110}, workspace, "en").text =~
             "status expired"

    blocked = put_in(result, [:device, "allows_operations"], false)
    assert ChatDeviceView.render(blocked, workspace, "en").text =~ "device permission required"
    offline = put_in(result, [:device, "status"], "disconnected")
    assert ChatDeviceView.render(offline, workspace, "en").text =~ "device offline"
  end
end
