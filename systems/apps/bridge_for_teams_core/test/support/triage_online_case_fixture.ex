defmodule BridgeForTeams.TriageOnlineCaseFixture do
  @moduledoc """
  De-identified frozen-input replays of the two 2026-09-07 online cases.

  This enters at the evaluator, deliberately preserving the context that the
  online model actually saw rather than rebuilding it from the synthetic
  twelve-meeting fixture. It does NOT prove ingestion, context assembly, the
  Runtime fence, Task execution or Slack delivery. Those are separate product
  composition checks. The current evaluator/prompt and source tool are the
  treatment, including the current runtime profile's output budget; historical
  model identity and wire options remain provenance, never runtime defaults.
  """

  import ExUnit.Assertions

  alias BridgeForTeams.TriageEngineFixture, as: Fixture
  alias BridgeForTeams.TriageEngineLiveHarness, as: Harness
  alias SalixIM.Triage.CanonicalJSON

  @fixture Path.expand("../fixtures/triage/online_cases_20260907.json", __DIR__)
  @external_resource @fixture
  @cases @fixture |> File.read!() |> Jason.decode!() |> Map.fetch!("cases")
  @authority_keys ~w(provider tenant_id group_id connect_id connect_generation workspace_id approved_channel_id inbound_agent_id app_id bot_user_id bot_id)

  def fetch!(id), do: Enum.find(@cases, &(&1["id"] == id)) || raise("unknown online case")

  def model_input(id), do: encode_input(fetch!(id)["snapshot"])

  @doc """
  Re-runs only the current source actor projection for the captured token case.

  The raw author/subtype shape was separately verified in its stored private
  source observation. The actual CH reader derives the new kind; no fixture
  chooses a desired classification. All other frozen fields remain identical.
  This is not a new full ingestion/freeze replay and does not restore files.
  """
  def current_source_model_input("token_report_no_tools" = id, authority) do
    snapshot = fetch!(id)["snapshot"]
    [captured] = snapshot["slack_context"]["messages"]
    observed = fetch!(id)["source_actor_observation"]
    assert observed["user_present"]

    refute observed["bot_id_present"] or observed["bot_profile_present"] or
             observed["app_id_present"]

    root_ts = "1787019000.000001"

    Fixture.put_thread([
      Fixture.mirrored_message(root_ts, "U_CAPTURED_HUMAN", captured["text"])
      |> Map.put("subtype", observed["subtype"])
    ])

    source =
      Map.merge(authority, %{
        "channel_id" => authority["approved_channel_id"],
        "thread_ts" => root_ts
      })

    # Release-composition fixtures load salix_web at runtime; core must not
    # acquire a reverse compile dependency on its web composition root.
    assert {:ok, %{"messages" => [projected]}} =
             apply(Salix.Bindings.ClickHouseTriageThreadReader, :read, [
               source,
               authority,
               [reader: Fixture.ClickHouseReader]
             ])

    snapshot
    |> put_in(["slack_context", "messages"], [
      Map.put(captured, "actor_kind", projected["actor_kind"])
    ])
    |> encode_input()
  end

  defp encode_input(snapshot) do
    snapshot_bytes = CanonicalJSON.encode!(snapshot)
    refs = snapshot["decision_contract"]["source_refs"]
    refs_bytes = CanonicalJSON.encode!(refs)

    %{
      "schema" => "comma.triage-model-input.v3",
      "snapshot" => snapshot,
      "canonical_snapshot_bytes" => snapshot_bytes,
      "canonical_snapshot_sha256" => CanonicalJSON.sha256(snapshot_bytes),
      "source_refs" => refs,
      "source_refs_canonical_bytes" => refs_bytes,
      "source_refs_sha256" => CanonicalJSON.sha256(refs_bytes)
    }
  end

  def replay(id, profile, opts \\ []) do
    # Replay the captured input through the current runtime profile and product
    # policy. Historical wire options describe the old run, not this treatment.
    authority = Fixture.seed_authority!()
    Harness.seed_agent_template!(authority, profile)

    assert {:ok, provider_opts} =
             SalixAgent.LlmResolver.resolve_runtime(authority["inbound_agent_id"])

    input =
      case Keyword.get(opts, :source_projection, :historical) do
        :historical -> model_input(id)
        :current -> current_source_model_input(id, authority)
      end

    apply(Salix.Bindings.TriageEvaluator, :evaluate, [
      input,
      [
        provider: Harness.live_provider(),
        provider_name: provider_opts["provider"],
        provider_opts: provider_opts,
        read_tool_context: source_context(id, authority),
        transport_receipt: fn bytes ->
          %{payload_sha256: CanonicalJSON.sha256(bytes), request_count: 1}
        end
      ]
    ])
  end

  defp source_context("token_report_no_tools", _authority) do
    Fixture.put_linked_message(nil)
    nil
  end

  defp source_context("bare_forwarded_reply", authority) do
    # Same semantic content and reply-permalink shape as the referenced post;
    # tenant coordinates and media filename are de-identified. Later replies
    # are intentionally absent. Source text is untrusted, not a verified result
    # of this replay's own media search.
    Fixture.put_linked_message(%{
      "workspace_url" => "https://atlas.slack.com/",
      "ts" => "1788736779.888319",
      "thread_ts" => "1788653179.558079",
      "user" => "U_BFT",
      "text" => """
      这次找到一个很像你要的 HomePod 实物视频：<https://atlas.slack.com/archives/C_MEDIA/p1788430415733169|打开原视频消息>。文件名 `IMG_4242.MOV`，约 12 秒。

      我核对了抽帧：桌面上有黑白两只球形音箱，顶部先后亮起蓝光，旁边是显示器和植物。这次不是之前的 Siri 网页录屏。你看看是不是这条？

      另外两张图还在处理：新版全历史视频检索已成功，但摄影棚和手绘架构图的全历史图片检索仍报错，暂时不能把它们当成“没找到”。
      """
    })

    %{
      agent_id: authority["inbound_agent_id"],
      session_id: "local-online-case-replay",
      tenant_id: authority["tenant_id"],
      group_id: authority["group_id"],
      role: "router",
      runtime_kind: :internal,
      llm_tool_envelope: true,
      visible_reply_phase: :clean,
      triage_read_once: true,
      tool_name: "triage.slack_read_permalink",
      slack_source_authority: Map.take(authority, @authority_keys),
      tool_disclosure: apply(Salix.Bindings.TriageSlackRead, :disclosure, []),
      link_targets: [
        %{
          "link_ref" => "link://run/l001",
          "source_refs" => ["source://run/s005"],
          "resolved_url" =>
            "https://atlas.slack.com/archives/C_ATLAS/p1788736779888319?thread_ts=1788653179.558079&cid=C_ATLAS"
        }
      ]
    }
  end
end
