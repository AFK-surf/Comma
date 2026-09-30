defmodule BridgeForTeams.TriageCollaborationCorpusTest do
  use ExUnit.Case, async: true
  alias BridgeForTeams.TriageCollaborationCorpus, as: Corpus
  alias BridgeForTeams.TriageInvestigationContext, as: Context

  @authority %{
    "tenant_id" => "local-tenant",
    "group_id" => "local-group",
    "connect_id" => "local-connect",
    "connect_generation" => "local-generation",
    "workspace_id" => "T_ATLAS",
    "approved_channel_id" => "C_ATLAS"
  }

  test "eight distinct source threads cover four groups without leaking later messages" do
    cases = Corpus.cases()
    assert length(cases) == 8
    assert length(Enum.uniq_by(cases, &{&1["source_channel"], &1["root_ts"]})) == 8
    assert Enum.frequencies_by(cases, &Corpus.entrypoint/1) == %{triage: 4, direct_command: 4}

    assert cases |> Enum.frequencies_by(& &1["group"]) |> Map.values() |> Enum.sort() == [
             2,
             2,
             2,
             2
           ]

    for case_data <- cases do
      rows = case_data["source_messages"] ++ case_data["retrievable_messages"]
      assert Enum.all?(rows, &(&1["ts"] <= case_data["cutoff_ts"]))
      refute Enum.any?(rows, &(&1["ts"] in case_data["held_out_message_ts"]))

      assert Enum.count(
               case_data["source_messages"],
               &(&1["ts"] == case_data["input_message_ts"])
             ) == 1

      refute Jason.encode!(rows) =~ ~r/\b(?:U0|C09|T09|F0)[A-Z0-9]+/
      refute Jason.encode!(rows) =~ "@comma.surf"
    end
  end

  test "casual participation uses the original turn without injecting the later investigation ask" do
    [casual] = Corpus.participation_cases()
    original = Corpus.fetch!("historical_message_sources")

    assert (casual["source_messages"] ++ casual["retrievable_messages"])
           |> Enum.sort_by(& &1["ts"]) ==
             Enum.sort_by(original["retrievable_messages"], & &1["ts"])

    assert Corpus.entrypoint(casual) == :triage
    context = Corpus.build(casual, @authority, "http://127.0.0.1:9999/api")
    assert [%{"text" => "二郎了", "ts" => ts, "thread_ts" => ts}] = context.source_messages
    assert ts == casual["input_message_ts"]
    assert Enum.all?(context.messages, &(&1["ts"] <= casual["cutoff_ts"]))
    refute Jason.encode!(context.messages) =~ "原纪录看看"
    refute Map.has_key?(context, :expected)
  end

  test "direct correction controls preserve the captured Calendar source and keep synthetic inputs separate" do
    [calendar, apology, answer] = Corpus.direct_correction_cases()
    original = Corpus.fetch!("calendar_source_conflict")
    assert calendar["source_case_id"] == original["id"]
    assert calendar["source_messages"] == original["source_messages"]
    assert calendar["retrievable_messages"] == original["retrievable_messages"]
    assert calendar["cutoff_ts"] == original["cutoff_ts"]
    assert calendar["id"] != original["id"]

    for control <- [apology, answer] do
      assert control["sample_kind"] == "synthetic_direct_control"
      assert control["retrievable_messages"] == []
      assert Corpus.entrypoint(control) == :direct_command
      context = Corpus.build(control, @authority, "http://127.0.0.1:9999/api")
      refute Map.has_key?(context, :expected)

      refute Enum.any?(
               context.messages,
               &String.contains?(&1["text"], "Technical Design Meeting")
             )
    end
  end

  test "the full integration thread is paged before its cutoff and keeps the actual transcript" do
    case_data = Corpus.fetch!("meeting_integrations_confirm")
    context = Corpus.build(case_data, @authority, "http://127.0.0.1:9999/api")
    assert length(context.source_messages) == 33
    assert hd(case_data["source_messages"])["text"] =~ "<@U_BFT|Bridge For Teams>"
    assert hd(context.source_messages)["text"] =~ "<@U_BFT>"
    refute Enum.any?(context.source_messages, &Regex.match?(~r/<@[A-Z0-9_]+\|/u, &1["text"]))
    refute Map.has_key?(context, :expected)
    refute Map.has_key?(context, :held_out_message_ts)

    first =
      Context.slack_response(context, "conversations.replies", %{
        "channel" => "C_ATLAS",
        "ts" => case_data["root_ts"],
        "limit" => "20"
      })

    assert first["has_more"]

    second =
      Context.slack_response(context, "conversations.replies", %{
        "channel" => "C_ATLAS",
        "ts" => case_data["root_ts"],
        "limit" => "20",
        "cursor" => first["response_metadata"]["next_cursor"]
      })

    refute second["has_more"]
    assert first["messages"] ++ second["messages"] == context.source_messages
    assert List.last(second["messages"])["text"] == "会议里还讨论了很多呢你先看看 先别加 跟我确认再加"

    [{file_id, file}] = Enum.filter(context.files, fn {_id, entry} -> is_binary(entry.body) end)
    assert file.body =~ "["
    assert file.body =~ "Google"
    assert {:ok, metadata, body} = Corpus.file_response(context, file_id)
    assert body == file.body
    assert metadata["size"] == byte_size(body)
    assert metadata["url_private_download"] == "http://127.0.0.1:9999/files/#{file_id}"

    assert {:error, :local_fixture_file_not_captured} =
             Corpus.file_response(context, "FUNOBSERVED")
  end

  test "the supplied subscription screenshot remains the source instead of its later unread-image reply" do
    scenario = Corpus.subscription_screenshot_original()
    assert Corpus.entrypoint(scenario) == :triage
    assert [message] = scenario["source_messages"]
    assert message["text"] == "这个会封号吗 :doge:"
    assert message["ts"] == scenario["cutoff_ts"]
    assert scenario["retrievable_messages"] == []
    assert scenario["held_out_message_ts"] == ["1789106624.692999"]
    assert [%{"id" => "FSUBSCRIPTION001", "mimetype" => "image/png"}] = message["files"]
    refute Jason.encode!(scenario["source_messages"]) =~ "Claude"
    refute Jason.encode!(scenario["source_messages"]) =~ "看不到图片"
    assert length(Corpus.cases()) == 8
  end

  test "old message authors are independent source facts and future bot explanations are absent" do
    case_data = Corpus.fetch!("historical_message_sources")
    context = Corpus.build(case_data, @authority, "http://127.0.0.1:9999/api")
    erlang = Enum.find(context.messages, &(&1["text"] == "卧槽真 erlang 了"))
    pun = Enum.find(context.messages, &(&1["text"] == "二郎了"))
    assert erlang["user"] == "U10COLLAB07"
    assert pun["user"] == "U10COLLAB04"
    assert erlang["ts"] == "1781239375.756569"
    assert pun["ts"] == "1781239666.916999"
    refute Enum.any?(context.messages, &(&1["ts"] == "1788406906.865189"))
  end

  test "calendar disagreement preserves the old bot as a claim, not an invented API snapshot" do
    case_data = Corpus.fetch!("calendar_source_conflict")
    context = Corpus.build(case_data, @authority, "http://127.0.0.1:9999/api")
    assert Enum.count(context.messages, &(&1["actor_kind"] == "bot")) == 1
    assert context.web_documents == []
    assert context.files == %{}
    assert Enum.any?(context.messages, &(&1["text"] =~ "我订阅了没写有这个"))
    refute Enum.any?(context.messages, &(&1["text"] =~ "个人日历"))
  end

  test "supplemental attachment request changes only the trigger, not source material or the eight cases" do
    original = Corpus.fetch!("meeting_action_detail")
    supplemental = Corpus.attachment_request()
    assert length(Corpus.cases()) == 8
    refute supplemental in Corpus.cases()
    assert supplemental["sample_kind"] == "captured_context_with_synthetic_attachment_request"
    assert supplemental["source_case_id"] == original["id"]
    assert Corpus.entrypoint(supplemental) == :direct_command

    before_trigger = fn case_data ->
      Enum.reject(case_data["source_messages"], &(&1["ts"] == case_data["input_message_ts"]))
    end

    assert before_trigger.(supplemental) == before_trigger.(original)
    assert supplemental["retrievable_messages"] == original["retrievable_messages"]
    assert supplemental["cutoff_ts"] == original["cutoff_ts"]

    original_context = Corpus.build(original, @authority, "http://127.0.0.1:9999/api")
    context = Corpus.build(supplemental, @authority, "http://127.0.0.1:9999/api")
    assert context.files == original_context.files
    assert is_binary(context.files["FCOLLAB001"].body)
    refute Map.has_key?(context, :expected)
  end
end
