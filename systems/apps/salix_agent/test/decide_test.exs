defmodule SalixAgent.DecideTest do
  use ExUnit.Case, async: false
  alias SalixAgent.{Decide, DecideFixture, SessionToolDispatch, ToolDisclosure}

  setup do
    endpoint = DecideFixture.start_provider()
    DecideFixture.put_env(:llm_metering_mod, DecideFixture.Meter)
    DecideFixture.put_env(:event_archive_mod, DecideFixture.Archive)
    DecideFixture.put_env(:decide_test_pid, self())
    DecideFixture.put_env(:decide_test_deny, false)
    agent = SalixAgent.TestSupport.new_agent_id()
    group = SalixStore.Ids.group_id_from_agent!(agent)

    ctx = %{
      agent_id: agent,
      group_id: group,
      tenant_id: SalixStore.Ids.tenant_id_from_group!(group),
      session_id: SalixStore.Ids.new_session_id(),
      round_id: "decide-test",
      role: "worker",
      runtime_kind: :internal,
      billing_context: %{"billing_account_id" => "decision-account"}
    }

    ctx =
      Map.put(ctx, :tool_disclosure, ToolDisclosure.materialize_static("worker", :internal, ctx))

    %{ctx: ctx, endpoint: endpoint}
  end

  test "bounded background admission shares capacity and sends each request once", %{ctx: ctx} do
    # Initialize the fixture connection before testing shared admission. Concurrent
    # first requests can hit Finch's pool_not_available startup race.
    assert {:ok, config} = Decide.config()
    assert {:ok, _, _} = SalixAgent.Decide.Provider.request(DecideFixture.args(), config)
    assert_receive {:decision_request, _, _, _}

    deadline = System.monotonic_time(:millisecond) + 5_000

    results =
      1..8
      |> Task.async_stream(
        fn _ ->
          Decide.call(DecideFixture.args(), ctx, admission_deadline: deadline) |> Jason.decode!()
        end,
        max_concurrency: 8
      )
      |> Enum.to_list()

    assert Enum.all?(results, &match?({:ok, %{"answers" => _}}, &1))

    for _ <- 1..8 do
      assert_receive {:decision_request, _, _, _}
      assert_receive {:decision_meter_after, _}
    end

    refute_receive {:decision_request, _, _, _}
  end

  test "background admission uses its deadline when the shared authority is busy", %{ctx: ctx} do
    :ok = :sys.suspend(SalixAgent.Decide.Limits)

    task =
      Task.async(fn ->
        Decide.call(DecideFixture.args(), ctx,
          admission_deadline: System.monotonic_time(:millisecond) + 5_000
        )
        |> Jason.decode!()
      end)

    try do
      Process.sleep(300)
      refute_receive {:decision_request, _, _, _}, 0
    after
      :ok = :sys.resume(SalixAgent.Decide.Limits)
    end

    assert %{"answers" => _} = Task.await(task)
    assert_receive {:decision_request, _, _, _}
    refute_receive {:decision_request, _, _, _}
  end

  test "expired background admission does not dispatch or bill", %{ctx: ctx} do
    assert %{"error" => %{"code" => "timeout"}} =
             Decide.call(DecideFixture.args(), ctx,
               admission_deadline: System.monotonic_time(:millisecond) - 1
             )
             |> Jason.decode!()

    refute_receive {:decision_request, _, _, _}
    refute_receive {:decision_meter_before, _}
  end

  test "JSON config applies defaults and rejects invalid explicit routing" do
    for {section, expected} <- [
          {%{"api_key" => "key"}, :defaults},
          {%{}, :disabled},
          {%{"api_key" => "key", "endpoint" => 42}, :disabled},
          {%{"api_key" => "key", "endpoint" => "ftp://example.com"}, :disabled},
          {%{"api_key" => "key", "model" => nil}, :disabled}
        ] do
      for {:salix_agent, :decide, config} <-
            SalixStore.ConfigJson.app_env(%{"decide" => section}) do
        Application.put_env(:salix_agent, :decide, config)
      end

      if expected == :defaults do
        assert {:ok, %{endpoint: "https://api.typesafe.ai/v1/systemone", model: "jev-1.13.0"}} =
                 Decide.config()
      else
        assert {:error, :not_configured} = Decide.config()
      end
    end
  end

  test "one HTTP request answers mixed questions and retains attribution and usage", %{ctx: ctx} do
    args = DecideFixture.args()
    [result] = SessionToolDispatch.execute([%{id: "decide-1", name: "decide", args: args}], ctx)
    refute result[:error]
    out = Jason.decode!(result.content)
    assert out["answers"]["source"]["choice"] == "meetings"
    assert out["answers"]["source"]["confidence_bp"] == 8123
    assert out["answers"]["relevant"]["probability_bp"] == 9234
    assert out["answers"]["priority"]["score_milli"] == 800
    refute Map.has_key?(out["answers"]["relevant"], "confidence_bp")
    assert_receive {:decision_request, "/v1/systemone", ["Bearer test-decide-secret"], request}
    assert request == Map.put(args, "model", "jev-fixture")
    assert_receive {:decision_meter_before, before}
    assert before.billing_context["billing_account_id"] == "decision-account"
    assert before.salix_agent_id == ctx.agent_id
    assert before.session_id == ctx.session_id

    assert_receive {:decision_meter_after,
                    %{usage: %{"prompt_tokens" => 123, "completion_tokens" => 7}}}

    assert_receive {:decision_archive, %{boundary: :llm_request} = archived}
    assert archived.agent_id == ctx.agent_id
    assert archived.session_id == ctx.session_id
    assert archived.round_id == "decide-test"
    assert Jason.decode!(archived.payload["request_body"]) == request
    refute Jason.encode!(archived.payload) =~ "test-decide-secret"
    assert_receive {:decision_archive, %{boundary: :llm_response} = response}
    assert Jason.encode!(response.payload) =~ "provider_response"
    refute_receive {:decision_request, _, _, _}
  end

  test "uncertainty remains data and provider errors never select a default", %{ctx: ctx} do
    out = Decide.call(DecideFixture.args("uncertain"), ctx) |> Jason.decode!()
    assert out["answers"]["source"]["confidence_bp"] == 100

    for state <- ["missing", "unknown", "large"] do
      assert %{"error" => %{"code" => "invalid_response"}} =
               Decide.call(DecideFixture.args(state), fresh_group(ctx)) |> Jason.decode!()
    end
  end

  test "invalid probabilities and mismatched answers never become decisions" do
    args = DecideFixture.args()

    valid = %{
      "model" => "jev",
      "usage" => %{"input_tokens" => 1, "output_tokens" => 1},
      "answers" => %{"relevant" => %{"type" => "noul", "noul" => 0.5}}
    }

    questions = Map.take(args["questions"], ["relevant"])

    assert {:error, :invalid_response} =
             Decide.decode(put_in(valid, ["answers", "relevant", "noul"], 1.1), questions)

    assert {:error, :invalid_response} =
             Decide.decode(put_in(valid, ["answers", "relevant", "type"], "choice"), questions)

    choice = %{
      "type" => "choice",
      "choice" => "meetings",
      "confidence" => 0.9,
      "probabilities" => %{"meetings" => 0.8, "none" => 0.8}
    }

    assert {:error, :invalid_response} =
             Decide.decode(
               %{valid | "answers" => %{"source" => choice}},
               Map.take(args["questions"], ["source"])
             )
  end

  test "two-decimal provider rounding is a decision, and a larger gap is not" do
    reply = fn answers ->
      %{
        "model" => "jev",
        "usage" => %{"input_tokens" => 1, "output_tokens" => 1},
        "answers" => answers
      }
    end

    choice = fn value, probabilities ->
      %{
        "type" => "choice",
        "choice" => value,
        "confidence" => 0.92,
        "probabilities" => probabilities
      }
    end

    actions = ~w(evaluate implement investigate prepare reply review verify)

    action = %{
      "type" => "choice",
      "instructions" => "Classify the requested action",
      "criteria" => Map.new(actions, &{&1, "Action #{&1}"})
    }

    # A staging Jev answer: seven options rounded to two decimals sum to 0.99.
    rounded = %{
      "evaluate" => 0.02,
      "implement" => 0,
      "investigate" => 0.01,
      "prepare" => 0,
      "reply" => 0.01,
      "review" => 0.02,
      "verify" => 0.93
    }

    assert {:ok, %{"answers" => %{"action" => decision}}, _} =
             Decide.decode(reply.(%{"action" => choice.("verify", rounded)}), %{
               "action" => action
             })

    assert decision["choice"] == "verify"
    assert decision["probabilities_bp"]["verify"] == 9300

    # Two options at the rounding bound: 0.505 and 0.495 are reported as 0.51 and 0.50.
    check = %{
      "type" => "choice",
      "instructions" => "Is the objective supported?",
      "criteria" => %{"supported" => "Supported", "unsupported" => "Unsupported"}
    }

    assert {:ok, _, _} =
             Decide.decode(
               reply.(%{
                 "check" => choice.("supported", %{"supported" => 0.51, "unsupported" => 0.5})
               }),
               %{"check" => check}
             )

    assert {:error, :invalid_response} =
             Decide.decode(
               reply.(%{"action" => choice.("verify", %{rounded | "verify" => 0.9})}),
               %{"action" => action}
             )
  end

  test "refused admission and disabled configuration do not contact the provider", %{ctx: ctx} do
    Application.put_env(:salix_agent, :decide_test_deny, true)
    assert error(Decide.call(DecideFixture.args(), ctx)) == "billing_unavailable"
    refute_receive {:decision_request, _, _, _}
    Application.put_env(:salix_agent, :decide, [])
    assert error(Decide.call(DecideFixture.args(), ctx)) == "not_configured"
    refute_receive {:decision_request, _, _, _}
  end

  test "invalid arguments cannot override routing or exceed the input bound", %{ctx: ctx} do
    assert error(Decide.call(Map.put(DecideFixture.args(), "endpoint", "http://attacker"), ctx)) ==
             "invalid_request"

    assert error(Decide.call(DecideFixture.args(String.duplicate("x", 12_288)), ctx)) ==
             "invalid_request"

    assert error(
             Decide.call(
               put_in(DecideFixture.args(), ["questions", "source", "criteria"], %{
                 "only" => "one"
               }),
               ctx
             )
           ) == "invalid_request"

    refute_receive {:decision_request, _, _, _}
  end

  test "timeouts, redirects and rate limits terminate without retry or credential disclosure", %{
    ctx: ctx
  } do
    for {state, expected} <- [
          {"slow", "timeout"},
          {"redirect", "provider_error"},
          {"rate", "rate_limited"}
        ] do
      started = System.monotonic_time(:millisecond)
      encoded = Decide.call(DecideFixture.args(state), fresh_group(ctx))
      assert error(encoded) == expected
      assert System.monotonic_time(:millisecond) - started < 2_800
      refute encoded =~ "test-decide-secret"
      assert_receive {:decision_request, "/v1/systemone", _, _}
      refute_receive {:decision_request, _, _, _}
    end
  end

  test "Group callers share limits while other Groups retain independent admission", %{ctx: ctx} do
    # Rapid calls span at most two fixed second windows.
    results = for _ <- 1..12, do: SalixAgent.Decide.Limits.admit(ctx.tenant_id, ctx.group_id)
    assert Enum.count(results, &(&1 == :ok)) <= 8
    assert {:error, :rate_limited} in results

    for n <- 1..610 do
      assert :ok = SalixAgent.Decide.Limits.admit(ctx.tenant_id, ctx.group_id <> "-other-#{n}")
    end
  end

  test "tool disclosure refusal prevents provider dispatch", %{ctx: ctx} do
    ctx = put_in(ctx, [:tool_disclosure, "tools"], [])

    [result] =
      SessionToolDispatch.execute(
        [%{id: "denied", name: "decide", args: DecideFixture.args()}],
        ctx
      )

    assert result[:guidance_reason] == "not_callable"
    refute_receive {:decision_request, _, _, _}
  end

  defp error(encoded), do: Jason.decode!(encoded)["error"]["code"]

  defp fresh_group(ctx),
    do:
      Map.put(
        ctx,
        :group_id,
        ctx.group_id <> Integer.to_string(System.unique_integer([:positive]))
      )
end
