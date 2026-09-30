defmodule SalixIM.Triage.ReadSourceContextTest do
  use ExUnit.Case, async: true

  alias SalixIM.Triage.ReadSourceContext

  @root "1787019000.000001"
  @reply "1787019001.000002"
  @thread "slack://T_ATLAS/C_ATLAS/#{@root}/#{@reply}"
  @channel "slack://T_ATLAS/C_OTHER/channel/#{@reply}"

  test "projects only public coordinates in source order without inventing a channel thread" do
    summary = context([@thread, "memory://private-runbook", @channel])
    [_, json] = String.split(summary, "): ", parts: 2)

    assert Jason.decode!(json) == %{
             "sources" => [
               %{
                 "provider" => "slack",
                 "workspace_id" => "T_ATLAS",
                 "channel_id" => "C_ATLAS",
                 "thread_ts" => @root,
                 "message_ts" => @reply,
                 "source_ref" => @thread
               },
               %{
                 "provider" => "slack",
                 "workspace_id" => "T_ATLAS",
                 "channel_id" => "C_OTHER",
                 "message_ts" => @reply,
                 "source_ref" => @channel
               }
             ]
           }

    for private <- [
          "private-connect",
          "private-obligation",
          "private-principal",
          "private-runbook"
        ] do
      refute summary =~ private
    end
  end

  test "ordinary Tasks and non-Worker recipients receive no Triage source projection" do
    rec = delivery([@thread])

    for other <- [
          Map.put(rec, "conversation_kind", "user_chat"),
          Map.put(rec, "participant_role_label", "delegator"),
          Map.put(rec, "participant_role_label", "router"),
          Map.put(rec, "conversation_source_refs", %{}),
          Map.delete(rec, "conversation_source_refs")
        ] do
      assert ReadSourceContext.content(other) == ""
    end
  end

  test "unusable sets are explicitly unavailable without rendering private or partial data" do
    for refs <- [
          [],
          ["memory://private-runbook"],
          [@thread, "slack://T_ATLAS/C_ATLAS/not-a-thread/#{@reply}"],
          [@thread, "slack://T_ATLAS/C_ATLAS/#{@root}/#{@reply}?private-principal"],
          [@thread, %{"connect_id" => "private-connect"}],
          [@thread, "slack://" <> String.duplicate("A", 257)],
          List.duplicate(@thread, 201)
        ] do
      summary = context(refs)
      assert summary =~ "sources: unavailable"
      refute summary =~ "slack://"
      refute summary =~ "private"
    end
  end

  test "the documented maximum remains finite without truncating valid sources" do
    max_id = String.duplicate("A", 64)
    ref = "slack://#{max_id}/#{max_id}/#{@root}/#{@reply}"
    summary = context(List.duplicate(ref, 200))
    [_, json] = String.split(summary, "): ", parts: 2)
    assert length(Jason.decode!(json)["sources"]) == 200
    assert byte_size(summary) < 100_000
    assert context([String.replace(ref, max_id, max_id <> "A")]) =~ "sources: unavailable"
  end

  defp context(refs), do: ReadSourceContext.content(delivery(refs))

  defp delivery(refs) do
    %{
      "conversation_kind" => "agent_task",
      "participant_role_label" => "worker",
      "conversation_source_refs" => %{
        "triage_source_refs" => refs,
        "triage_obligation_id" => "private-obligation",
        "triage_delegation_index" => 1,
        "connect_id" => "private-connect"
      },
      "message_metadata" => %{"principal_ref" => "private-principal"}
    }
  end
end
