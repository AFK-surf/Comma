defmodule SalixWeb.LarkSuiteTriageEvaluatorTest do
  @moduledoc """
  The Feishu / Lark triage model call is archived under the batch's own
  identity (systems/AGENTS.md, Agent event archive), and its answer becomes
  one decision.
  """

  use SystemsClock.Case, async: false

  alias SalixWeb.LarkSuiteTriageEvaluator

  @agent "agt1_2092243300810489856_2092243300810489857_2092243300810489858"

  defmodule Recorder do
    @moduledoc false
    @behaviour SalixAgent.EventArchive

    @impl true
    def record(fact) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.get_env(:salix_agent, :archive_test_pid),
        {:archived, fact}
      )

      :ok
    end
  end

  defmodule Model do
    @moduledoc false
    def complete(_messages, _tools), do: {:final, ~s(Sure: {"kind":"reaction","emoji_type":"OK"})}
    def complete(messages, tools, _opts), do: complete(messages, tools)
  end

  setup do
    previous =
      for key <- [:event_archive_mod, :llm], do: {key, SystemsRuntime.get_env(:salix_agent, key)}

    SystemsRuntime.put_env(:salix_agent, :event_archive_mod, Recorder)
    SystemsRuntime.put_env(:salix_agent, :archive_test_pid, SystemsRuntime.Proc.self())
    SystemsRuntime.put_env(:salix_agent, :llm, Model)
    SalixAgent.EventArchive.Accumulator.create_table()

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> SystemsRuntime.delete_env(:salix_agent, key)
        {key, value} -> SystemsRuntime.put_env(:salix_agent, key, value)
      end)

      SystemsRuntime.delete_env(:salix_agent, :archive_test_pid)
    end)

    :ok
  end

  test "the call is archived with the batch's identity and answers a decision" do
    identity =
      SalixIM.LarkSuiteTriage.identity(%{
        id: "ltb_1",
        tenant_id: SalixStore.Ids.tenant_id_from_agent!(@agent),
        group_id: "grp",
        connect_id: "con_lark",
        router_agent_id: @agent
      })

    assert {:ok, %{"kind" => "reaction", "emoji_type" => "OK"}} =
             LarkSuiteTriageEvaluator.evaluate(
               %{"messages" => [%{"text" => "部署好了"}]},
               identity
             )

    assert_received {:archived, request}
    assert_received {:archived, response}

    for fact <- [request, response] do
      assert fact.agent_id == @agent
      assert fact.session_id == "lark_suite_triage:con_lark:ltb_1"
      assert fact.round_id == "ltb_1"
      assert fact.tenant_id == SalixStore.Ids.tenant_id_from_agent!(@agent)
    end

    assert request.boundary == :llm_request
    assert response.boundary == :llm_response
  end

  defmodule FailingAnalyzeLLM do
    @moduledoc false
    def resolve(_agent_id), do: {:error, :no_model}
  end

  test "returns {:error, :model_unavailable} when AnalyzeLLM resolution fails" do
    identity =
      SalixIM.LarkSuiteTriage.identity(%{
        id: "ltb_no_model",
        tenant_id: SalixStore.Ids.tenant_id_from_agent!(@agent),
        group_id: "grp",
        connect_id: "con_lark",
        router_agent_id: @agent
      })

    assert {:error, :model_unavailable} =
             LarkSuiteTriageEvaluator.evaluate(
               %{"messages" => [%{"text" => "部署好了"}]},
               identity,
               analyze_llm: FailingAnalyzeLLM
             )
  end
end
