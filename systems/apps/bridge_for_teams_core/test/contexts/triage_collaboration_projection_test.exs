defmodule BridgeForTeams.TriageCollaborationProjectionTest do
  use BridgeForTeams.DataCase, async: false

  alias BridgeForTeams.TriageCollaborationCorpus, as: Corpus
  alias BridgeForTeams.TriageEngineFixture, as: Fixture
  alias BridgeForTeams.TriageEngineLiveHarness, as: Harness
  alias SalixStore.Ids

  defmodule StubProvider do
    def complete(messages, tools, opts) do
      for tool <- tools do
        assert Map.keys(tool["input_schema"]["properties"]) |> Enum.sort() == ~w(params tool)
      end

      bytes = Jason.encode!(%{"messages" => messages, "tools" => tools, "model" => opts["model"]})
      :ok = opts[:before_send].(bytes)

      context =
        messages
        |> Enum.find(&(&1.role == "user"))
        |> Map.fetch!(:content)
        |> Jason.decode!()

      SystemsRuntime.Proc.send(opts["test_pid"], {:projection_reached_provider, context})

      source =
        context
        |> get_in(["slack_context", "messages"])
        |> List.last()
        |> Map.fetch!("source_ref")

      schema = get_in(opts, ["response_format", "schema"])
      {:final, Jason.encode!(Harness.assignment_decision(schema, [source]))}
    end
  end

  setup do
    SalixStore.S3.Fake.reset()
    unless SystemsRuntime.Proc.whereis(Ids), do: start_supervised!(Ids)
    :ok = Fixture.install_clickhouse_reader!(SystemsRuntime.Proc.self())
    authority = Fixture.seed_authority!()
    project = Fixture.seed_project!(authority)
    Harness.seed_worker!(authority, project)
    %{authority: authority, project: project}
  end

  test "credential-bearing file names retain the existing pre-model rejection", %{
    authority: authority
  } do
    case_data = Corpus.fetch!("meeting_integrations_confirm")
    context = Corpus.build(case_data, authority, "http://127.0.0.1:9999/api")

    source_messages =
      List.update_at(context.source_messages, 2, fn message ->
        put_in(message, ["files", Access.at(0), "name"], "Bearer xoxb-catalogue-canary123")
      end)

    run = run!(source_messages, case_data, authority)
    assert run["status"] == "failed"
    assert run["decision"]["reason"] == "identity_projection_privacy_rejected"
    refute_receive {:projection_reached_provider, _}
  end

  @tag :dashboard_file_catalogue
  test "captured file catalogues survive the real engine into human-review source excerpts", %{
    authority: authority,
    project: project
  } do
    case_data = Corpus.fetch!("meeting_integrations_confirm")
    context = Corpus.build(case_data, authority, "http://127.0.0.1:9999/api")

    files =
      for index <- 1..13 do
        %{
          "id" => "F-REVIEW-PRIVATE-#{index}",
          "name" => if(index == 1, do: String.duplicate("会议", 260), else: "transcript.txt"),
          "mimetype" => "text/plain",
          "url_private" => "https://private.example.test/download?token=not-a-real-token"
        }
      end

    messages = List.update_at(context.source_messages, -1, &Map.put(&1, "files", files))
    provider_context = evaluate!(messages, case_data, authority)
    expected = List.last(provider_context["slack_context"]["messages"])["file_attachments"]
    assert expected["total_count"] == 13
    agent = Enum.find(BridgeForTeams.Agents.list_agents(project.id), &(&1.role == "router"))

    assert {:ok, %{outcomes: [outcome]}} =
             SalixIM.Triage.ReadModel.product_activity(
               project.id,
               authority["group_id"],
               agent.id
             )

    assert List.last(outcome.source.messages)[:file_attachments] == expected
    assert length(outcome.source.messages) <= 3

    for private <- ["F-REVIEW-PRIVATE", "private.example.test", "not-a-real-token"] do
      refute Jason.encode!(outcome.source) =~ private
    end
  end

  defp evaluate!(source_messages, case_data, authority) do
    run = run!(source_messages, case_data, authority)
    assert run["status"] == "evaluated", inspect(Map.take(run, ~w(status decision evaluator)))
    Harness.assert_worker_assignment!(run)
    refute_receive {:projection_reached_provider, _}
    Jason.decode!(run["input_snapshot"]["canonical_snapshot_bytes"])
  end

  defp run!(source_messages, case_data, authority) do
    Fixture.put_thread(source_messages)

    namespace =
      "triage-collaboration-projection-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    server =
      Fixture.start_engine!(
        namespace,
        {Salix.Bindings.TriageEvaluator,
         [
           provider: StubProvider,
           provider_opts: %{"test_pid" => SystemsRuntime.Proc.self()},
           transport_receipt: fn bytes ->
             %{payload_sha256: Fixture.sha256(bytes), request_count: 1}
           end
         ]}
      )

    trigger = Enum.find(source_messages, &(&1["ts"] == case_data["input_message_ts"]))

    Fixture.admit_reply!(
      server,
      authority,
      "Ev-projection-#{case_data["id"]}",
      trigger["ts"],
      trigger["text"],
      root_ts: case_data["root_ts"],
      actor_id: trigger["user"]
    )

    Fixture.await_run!(server)
  end
end
