defmodule SalixMeet.RuntimeDriver.SalixConnectTest do
  use ExUnit.Case, async: false

  alias SalixMeet.RuntimeDriver.SalixConnect

  defmodule CaptureDispatch do
    @behaviour SalixMeet.Ports.MeetingDispatch

    @impl true
    def join(payload) do
      send(self(), {:dispatched, payload})
      {:ok, %{"accepted" => true}}
    end

    @impl true
    def send_chat(_payload), do: {:error, :not_configured}

    @impl true
    def session_status(_payload), do: {:ok, :unavailable}
  end

  setup do
    prev = Application.get_env(:salix_meet, :meeting_dispatch_mod)
    Application.put_env(:salix_meet, :meeting_dispatch_mod, CaptureDispatch)
    on_exit(fn -> Application.put_env(:salix_meet, :meeting_dispatch_mod, prev) end)
    :ok
  end

  test "join builds the join payload and routes it through the dispatch port" do
    doc = %{
      "id" => "meet_1",
      "join_requested_at" => 123,
      "state" => %{
        "tenant_id" => "t1",
        "group_id" => "g1",
        "meet_url" => "https://meet.google.com/abc-defg-hij",
        "caption_language" => "English",
        "runtime_token" => "tok",
        "provider" => "slack",
        "meeting_agent_id" => "agent_1"
      }
    }

    assert {:ok, %{"accepted" => true}} = SalixConnect.join(doc)
    assert_receive {:dispatched, payload}

    assert payload["meeting_id"] == "meet_1"
    assert payload["meet_url"] == "https://meet.google.com/abc-defg-hij"
    assert payload["tenant_id"] == "t1"
    assert payload["group_id"] == "g1"
    assert payload["runtime_token"] == "tok"
    assert payload["caption_language"] == "English"
    assert payload["join_requested_at"] == 123
    refute Map.has_key?(payload, "callback_url")
  end

  test "join surfaces a dispatch error when no runtime is available" do
    Application.put_env(:salix_meet, :meeting_dispatch_mod, SalixMeet.Ports.MeetingDispatch.None)

    doc = %{"id" => "meet_2", "state" => %{"group_id" => "g1"}}

    assert {:error, :meeting_dispatch_not_configured} = SalixConnect.join(doc)
  end
end
