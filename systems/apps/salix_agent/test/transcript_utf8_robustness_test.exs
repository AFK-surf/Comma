defmodule SalixAgent.TranscriptUtf8RobustnessTest do
  use ExUnit.Case, async: false

  alias SalixAgent.InternalSessionStore

  @session "ses1_0000000000000000901"
  @activation_session "ses1_0000000000000000902"

  # "接入" cut one byte into its second character — the byte-truncation shape
  # that reached production: an invalid 0xE5 byte that ETF snapshots persist
  # silently and Jason.encode! later rejects on every LLM request.
  @truncated_cjk binary_part("接入", 0, 4)

  setup do
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    SalixStore.Repo.query!("TRUNCATE session_work_candidates")
    :ok
  end

  test "commit scrubs invalid UTF-8 out of every transcript-bound event field" do
    agent_id = "agt1_" <> Integer.to_string(System.unique_integer([:positive]))

    corrupt_prompt = "You are an agent.\n- 通过 Slack " <> @truncated_cjk
    corrupt_summary = "<compacted-context>\n当有人说" <> @truncated_cjk <> "\n</compacted-context>"
    corrupt_content = "tool output: " <> @truncated_cjk

    assert {:ok, session} =
             InternalSessionStore.prepare_commit(agent_id, @session, [
               %{"type" => "session_created", "session_id" => @session},
               %{
                 "type" => "session_system_prompt",
                 "session_id" => @session,
                 "system_prompt" => corrupt_prompt
               },
               %{
                 "type" => "assistant",
                 "session_id" => @session,
                 "message_id" => 1,
                 "content" => corrupt_content
               },
               %{
                 "type" => "compaction",
                 "session_id" => @session,
                 "summary" => corrupt_summary,
                 "compacted_through" => 0,
                 "summary_sequence" => 1
               }
             ])

    assert String.valid?(SalixAgent.InternalSession.get(session, :system_prompt))
    assert String.valid?(SalixAgent.InternalSession.get(session, :summary))
    assert SalixAgent.InternalSession.get(session, :system_prompt) =~ "通过 Slack 接�"
    assert SalixAgent.InternalSession.get(session, :summary) =~ "当有人说接�"

    for message <- SalixAgent.InternalSession.get(session, :messages) do
      assert String.valid?(message[:content])
    end

    # The wedge was request encoding: the exact strings Round sends must be
    # JSON-encodable again after a fresh read of the persisted state.
    assert {:ok, reread} = InternalSessionStore.read(agent_id, @session)
    assert {:ok, _} = Jason.encode(SalixAgent.InternalSession.get(reread, :system_prompt))
    assert {:ok, _} = Jason.encode(SalixAgent.Compaction.context(reread))

    assert {:ok, _} = InternalSessionStore.prepare_create(agent_id, @activation_session, %{})

    assert {:ok, _} =
             Registry.register(
               SalixAgent.Registry,
               SalixAgent.InternalSessionActor.key(agent_id, @activation_session),
               nil
             )

    assert {:ok, revision} = InternalSessionStore.read_revision(agent_id, @activation_session)

    leading = [
      %{
        "type" => "session_event",
        "kind" => "context",
        "event" => %{"content" => corrupt_content}
      }
    ]

    assert {:ok, activated, nil} =
             SalixAgent.InternalSession.Command.run(
               agent_id,
               @activation_session,
               revision,
               :activate,
               {leading, 5, corrupt_prompt, true}
             )

    assert SalixAgent.InternalSession.get(activated.state, :system_prompt) =~ "通过 Slack 接�"
    assert {:ok, activated_reload} = InternalSessionStore.read(agent_id, @activation_session)

    assert {:ok, _} =
             Jason.encode(SalixAgent.InternalSession.get(activated_reload, :system_prompt))

    assert {:ok, _} = Jason.encode(SalixAgent.InternalSession.get(activated_reload, :events))
  end
end
