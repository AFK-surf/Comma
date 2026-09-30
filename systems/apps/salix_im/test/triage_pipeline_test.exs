defmodule SalixIM.Triage.PipelineTest do
  use ExUnit.Case, async: true

  alias SalixIM.Triage.{IdentityFenceHandle, Pipeline}

  defmodule CompatibilityEvaluator do
    def evaluate(input, opts) do
      send(opts[:test_pid], {:compatibility_evaluated, input})
      {:ok, %{"action" => "silence"}, %{"evaluator" => "compatibility-stub"}}
    end
  end

  test "callback context authority cannot contain a static identity allowlist" do
    handle = %IdentityFenceHandle{runtime: self(), capability: make_ref()}
    input = %{"schema" => "comma.triage-input-snapshot.v2", "source_mode" => "callback"}

    assert :ok =
             Pipeline.validate_context_port(input, {
               :"Elixir.BridgeForTeams.TriageContext",
               identity_fence_handle: handle
             })

    assert {:error, :invalid_identity_diagnostic_configuration} =
             Pipeline.validate_context_port(input, {
               :"Elixir.BridgeForTeams.TriageContext",
               identity_fence_handle: handle,
               identity_allowlist: %{"project_id" => "caller-controlled"}
             })
  end

  test "historical compatibility may carry a fixture allowlist but rejects arbitrary ports" do
    handle = %IdentityFenceHandle{runtime: self(), capability: make_ref()}

    input = %{
      "schema" => "comma.triage-input-snapshot.v2",
      "source_mode" => "historical_thread_reenactment"
    }

    assert :ok =
             Pipeline.validate_context_port(input, {
               :"Elixir.BridgeForTeams.TriageContext",
               identity_fence_handle: handle, identity_allowlist: %{}
             })

    assert {:error, :invalid_identity_diagnostic_configuration} =
             Pipeline.validate_context_port(input, {
               :"Elixir.ForeignContext",
               identity_fence_handle: handle
             })
  end

  test "identity run rejects a non-capability authority before invoking ports" do
    input = %{
      "schema" => "comma.triage-input-snapshot.v2",
      "source_mode" => "callback",
      "events" => []
    }

    assert {:error, :identity_projection_invalid} =
             Pipeline.run_identity(input, nil, nil, :none, :caller_authority)
  end

  test "legacy context-free evaluation is owned by the compatibility pipeline" do
    input = %{
      "schema" => "comma.triage-input-snapshot.v1",
      "generation" => "legacy-generation",
      "events" => [%{"event_id" => "legacy-event"}],
      "receipt_refs" => [],
      "source_authority" => %{}
    }

    assert {:ok, %{"action" => "silence"}, %{"evaluator" => "compatibility-stub"}} =
             Pipeline.run_compatibility(
               input,
               nil,
               {CompatibilityEvaluator, test_pid: self()},
               :none,
               "unused-context-free-authority"
             )

    assert_receive {:compatibility_evaluated, ^input}
  end

  test "builds and validates the sealed callback input contract outside Runtime" do
    event = %{
      "source_mode" => "callback",
      "endpoint_provenance" => %{
        "schema" => "comma.slack-endpoint-provenance.v1",
        "captured_at_ms" => 1_780_000_000_000,
        "callback_api_app_id" => "A_BFT",
        "fast_path_bot_user_id" => "U_BFT",
        "endpoint_revision_sha256" => String.duplicate("b", 64)
      },
      "connect_generation" => "generation-1",
      "bucket" => %{
        "workspace_id" => "T_WORKSPACE",
        "channel_id" => "C_CHANNEL",
        "thread_ts" => "200.000",
        "scope_kind" => "channel"
      }
    }

    sealed = %{
      "generation" => "generation-sealed",
      "receipts" => [
        %{
          "connect_id" => "connect-1",
          "receipt_ref" => "receipt-1",
          "triage_event" => event
        }
      ]
    }

    assert {:ok, input} = Pipeline.build_input(sealed)
    assert input["schema"] == "comma.triage-input-snapshot.v2"
    assert input["source_mode"] == "callback"
    assert input["events"] == [event]
    assert input["receipt_refs"] == ["receipt-1"]
    assert input["source_authority"]["scope_kind"] == "channel"
    assert :ok = Pipeline.validate_input(input)

    drifted = put_in(input, ["source_mode"], "historical_thread_reenactment")
    assert {:error, :identity_source_mode_drift} = Pipeline.validate_input(drifted)
  end

  test "normalizes identity terminal and late-result contracts without leaking errors" do
    assert Pipeline.terminal_from_result(
             {:error, :identity_projection_invalid},
             :identity,
             123
           ) == %{
             "status" => "failed",
             "decision" => %{
               "action" => "silence",
               "reason" => "identity_projection_invalid"
             },
             "evaluator" => %{},
             "settled_at" => 123
           }

    assert Pipeline.result_parts({:error, {:secret, "must-not-persist"}}, :identity) ==
             {"failed",
              %{"action" => "silence", "reason" => "identity_diagnostic_internal_error"}, %{}}

    assert Pipeline.result_parts({:error, :invalid_triage_decision}, :identity) ==
             {"failed", %{"action" => "silence", "reason" => "identity_decision_invalid"}, %{}}

    assert Pipeline.valid_identity_late_result?({:error, :identity_decision_invalid})
    refute Pipeline.valid_identity_late_result?({:ok, %{}, %{}})
  end

  test "provider rejection settles as transport indeterminate without private error details" do
    terminal =
      Pipeline.terminal_from_result(
        {:error, {:provider_error, %{status: 502, body: "PRIVATE_PROVIDER_BODY"}}},
        :identity,
        123
      )

    assert terminal["status"] == "failed"
    assert terminal["decision"]["reason"] == "identity_diagnostic_indeterminate_transport"
    assert terminal["evaluator"] == %{}
    refute inspect(terminal) =~ "PRIVATE_PROVIDER_BODY"

    assert SalixIM.Triage.RunFence.valid_terminal?(
             Map.put(terminal, "terminal_id", SalixStore.ULID.generate())
           )
  end

  # A refused observed read is a real, operator-visible outcome, and every one
  # of these is already a committable terminal reason. Collapsing them into
  # `identity_diagnostic_internal_error` told the operator the engine had broken
  # when the truth was "this thread is wider than the authorized read" or
  # "Slack rate-limited us".
  test "a refused observed read settles under its own operator-visible reason" do
    assert Pipeline.result_parts({:error, :triage_slack_context_truncated}, :identity) ==
             {"failed", %{"action" => "silence", "reason" => "page_budget_exceeded"}, %{}}

    assert Pipeline.result_parts({:error, :lease_denied}, :identity) ==
             {"failed", %{"action" => "silence", "reason" => "lease_denied"}, %{}}

    assert Pipeline.result_parts({:error, :chain_deadline_exceeded}, :identity) ==
             {"failed", %{"action" => "silence", "reason" => "chain_deadline_exceeded"}, %{}}

    for reason <- ~w(slack_error rate_limited http_error transport_error decode_error)a do
      expected = Atom.to_string(reason)

      assert Pipeline.result_parts({:error, reason}, :identity) ==
               {"failed", %{"action" => "silence", "reason" => expected}, %{}}
    end

    # The catch-all still owns everything it should: an unrecognized shape never
    # becomes a transport reason.
    assert Pipeline.result_parts({:error, :something_else}, :identity) ==
             {"failed",
              %{"action" => "silence", "reason" => "identity_diagnostic_internal_error"}, %{}}

    # And the reason is durable, not just returned: the fence accepts this exact
    # terminal, so `page_budget_exceeded` is what the ledger record carries.
    {status, decision, evaluator} =
      Pipeline.result_parts({:error, :triage_slack_context_truncated}, :identity)

    assert SalixIM.Triage.RunFence.valid_terminal?(%{
             "terminal_id" => SalixStore.ULID.generate(),
             "status" => status,
             "decision" => decision,
             "evaluator" => evaluator,
             "settled_at" => 1
           })
  end
end
