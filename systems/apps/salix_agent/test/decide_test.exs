defmodule SalixAgent.DecideTest do
  use SystemsClock.Case, async: false
  require SystemsRuntime.Proc
  use SalixAgent.TestSupport.Settle
  alias SalixAgent.{Decide, DecideFixture, SessionToolDispatch, ToolDisclosure}

  defmodule StartingPool do
    require SystemsRuntime.Proc

    def child_spec(args) do
      Finch.HTTP1.Pool.child_spec(args)
      |> Map.put(:start, {__MODULE__, :start_link, [args]})
    end

    def start_link({_pool, _name, registry, _config, _index} = args) do
      {:ok, owner} = Registry.meta(registry, :startup_owner)
      monitor = SystemsRuntime.Proc.monitor(owner)

      try do
        SystemsRuntime.Proc.send(owner, {:pool_starting, SystemsRuntime.Proc.self()})

        SystemsRuntime.Proc.receive do
          :start_pool -> Finch.HTTP1.Pool.start_link(args)
          {:DOWN, ^monitor, :process, ^owner, _} -> {:error, :test_finished}
        end
      after
        SystemsRuntime.Proc.demonitor(monitor, [:flush])
      end
    end
  end

  setup do
    endpoint = DecideFixture.start_provider()
    DecideFixture.put_env(:llm_metering_mod, DecideFixture.Meter)
    DecideFixture.put_env(:event_archive_mod, DecideFixture.Archive)
    DecideFixture.put_env(:decide_test_pid, SystemsRuntime.Proc.self())
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
    settle_receive({:decision_request, "/v1/systemone", ["Bearer test-decide-secret"], request})
    assert request == Map.put(args, "model", "jev-fixture")
    settle_receive({:decision_meter_before, before})
    assert before.billing_context["billing_account_id"] == "decision-account"
    assert before.salix_agent_id == ctx.agent_id
    assert before.session_id == ctx.session_id

    settle_receive(
      {:decision_meter_after, %{usage: %{"prompt_tokens" => 123, "completion_tokens" => 7}}}
    )

    settle_receive({:decision_archive, %{boundary: :llm_request} = archived})
    assert archived.agent_id == ctx.agent_id
    assert archived.session_id == ctx.session_id
    assert archived.round_id == "decide-test"
    assert Jason.decode!(archived.payload["request_body"]) == request
    refute Jason.encode!(archived.payload) =~ "test-decide-secret"
    settle_receive({:decision_archive, %{boundary: :llm_response} = response})
    assert Jason.encode!(response.payload) =~ "provider_response"
    settle_refute_receive({:decision_request, _, _, _})
  end

  test "refused admission and disabled configuration do not contact the provider", %{ctx: ctx} do
    SystemsRuntime.put_env(:salix_agent, :decide_test_deny, true)
    assert error(Decide.call(DecideFixture.args(), ctx)) == "billing_unavailable"
    settle_refute_receive({:decision_request, _, _, _})
    SystemsRuntime.put_env(:salix_agent, :decide, [])
    assert error(Decide.call(DecideFixture.args(), ctx)) == "not_configured"
    settle_refute_receive({:decision_request, _, _, _})
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

    settle_refute_receive({:decision_request, _, _, _})
  end

  test "tool disclosure refusal prevents provider dispatch", %{ctx: ctx} do
    ctx = put_in(ctx, [:tool_disclosure, "tools"], [])

    [result] =
      SessionToolDispatch.execute(
        [%{id: "denied", name: "decide", args: DecideFixture.args()}],
        ctx
      )

    assert result[:guidance_reason] == "not_callable"
    settle_refute_receive({:decision_request, _, _, _})
  end

  defp error(encoded), do: Jason.decode!(encoded)["error"]["code"]
end
