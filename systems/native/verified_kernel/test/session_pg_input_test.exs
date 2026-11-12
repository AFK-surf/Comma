defmodule SalixVerifiedKernel.SessionPGInputTest do
  use ExUnit.Case, async: true
  alias SalixVerifiedKernel.Session

  @session "ses1_0000000000000000001"

  test "a repeated body advances a new Conversation source position without repeating workspace effects" do
    source = %{
      "conversation_id" => "conversation",
      "participant_id" => "participant",
      "generation" => @session,
      "seq" => 1
    }

    state =
      Session.new("agent", @session)
      |> Session.export()
      |> Map.merge(%{
        input_dedupe: MapSet.new(["source-1"]),
        conversation_sources: %{"participant" => source}
      })
      |> Session.open()

    entry = %{
      source_message_id: "source-1",
      conversation_source: %{source | "seq" => 2},
      payload: %{
        content: "already accepted",
        events: [%{"type" => "vfs_write", "path" => "file", "content" => "original"}]
      }
    }

    {_command, response} =
      state
      |> Session.start_revision(1)
      |> Session.start_command(:conversation_input, {entry, false}, nil, fn _, _ -> :ok end)

    assert {:validate_write,
            [%{"type" => "conversation_source_advance", "source" => %{"seq" => 2}}]} = response
  end
end
