defmodule SalixAgent.CondensedWorkspaceE2ETest do
  @moduledoc """
  The Condensed Workspace through real Session rounds: the provider request,
  the tool dispatch, the decision check beside the tools, and delivery to
  another Session of the same Group (docs/agent-runtime.md#condensed-workspace).
  """
  use SystemsClock.Case, async: false
  require SystemsClock

  use SalixAgent.TestSupport.Settle
  alias SalixAgent.{DecideFixture, InternalSession, InternalSessionStore, LLM}
  alias SalixStore.CondensedWorkspaces
  alias SalixStore.S3

  @first "ses1_0000000000000000971"
  @second "ses1_0000000000000000972"

  defmodule ScriptLLM do
    @moduledoc false
    @behaviour LLM
    @owner_key {__MODULE__, :owner}

    def set_owner(owner), do: SystemsRuntime.PersistentTerm.put(@owner_key, owner)
    def clear_owner, do: SystemsRuntime.PersistentTerm.erase(@owner_key)

    @impl true
    def complete(messages, tools) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.PersistentTerm.get(@owner_key),
        {:cw_llm_request, SystemsRuntime.Proc.self(), messages, tools}
      )

      SystemsClock.vreceive do
        {:cw_llm_response, response} -> response
      after
        5_000 -> raise "timed out waiting for a condensed workspace test response"
      end
    end
  end

  defmodule PhaseCollector do
    @moduledoc false
    @behaviour SalixAgent.Observability

    @impl true
    def tool_call(_fact), do: :ok

    @impl true
    def agent_run(_fact), do: :ok

    @impl true
    def inbox_dead_letter(_fact), do: :ok

    @impl true
    def llm_attempt(_fact), do: :ok

    @impl true
    def round_phase(fact) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.PersistentTerm.get({__MODULE__, :owner}),
        {:phase, fact}
      )

      :ok
    end
  end

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    SalixStore.Repo.query!("TRUNCATE session_work_candidates")

    previous =
      for key <- [
            :llm,
            :session_actor_idle_ms,
            :agent_observability_mod
          ],
          do: {key, SystemsRuntime.fetch_env(:salix_agent, key)}

    previous_store = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, S3.Fake)
    if SystemsRuntime.Proc.whereis(S3.Fake), do: S3.Fake.reset(), else: start_supervised!(S3.Fake)

    ScriptLLM.set_owner(SystemsRuntime.Proc.self())
    SystemsRuntime.PersistentTerm.put({PhaseCollector, :owner}, SystemsRuntime.Proc.self())
    SystemsRuntime.put_env(:salix_agent, :agent_observability_mod, PhaseCollector)
    SystemsRuntime.put_env(:salix_agent, :llm, ScriptLLM)
    SystemsRuntime.put_env(:salix_agent, :session_actor_idle_ms, 5_000)

    DecideFixture.start_provider()

    DecideFixture.put_env(:decide_noul_probabilities, %{
      "needs_update" => 0.9,
      "off_track" => 0.1,
      "statement_1" => 0.9
    })

    agent_id = SalixAgent.TestSupport.new_agent_id()
    group_id = SalixStore.Ids.group_id_from_agent!(agent_id)
    SalixAgent.TestSupport.create_control_agent!(agent_id)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      ScriptLLM.clear_owner()

      if previous_store,
        do: SystemsRuntime.put_env(:salix_store, :s3_backend, previous_store),
        else: SystemsRuntime.delete_env(:salix_store, :s3_backend)

      for {key, value} <- previous do
        case value do
          {:ok, value} -> SystemsRuntime.put_env(:salix_agent, key, value)
          :error -> SystemsRuntime.delete_env(:salix_agent, key)
        end
      end
    end)

    {:ok, agent_id: agent_id, group_id: group_id}
  end

  test "an update reaches another Session; the writer gets the check's reminder, not a copy", %{
    agent_id: agent_id,
    group_id: group_id
  } do
    SalixAgent.TestSupport.create_control_group!(group_id, %{
      "condensed_workspace_enabled" => true
    })

    deliver!(agent_id, @first, "src-1", "Record that the launch moved to Friday.")

    {pid, messages, _tools} = await_request!()
    assert text(messages) =~ "Condensed Workspace, revision 0"

    SystemsRuntime.Proc.send(
      pid,
      {:cw_llm_response,
       {:assistant, "",
        [
          %{
            id: "cw-1",
            name: "call",
            args: %{
              "tool" => "condensed_workspace.update",
              "params" => %{
                "operations" => [%{"op" => "add", "text" => "The launch is on Friday."}]
              }
            }
          }
        ]}}
    )

    # The update was checked before it applied, and the round check ran
    # beside the tool with the workspace and this round's call.
    # The two checks run concurrently, so they arrive in either order.
    states = for _ <- 1..2, do: await_decision!()
    suitability = Enum.find(states, &Map.has_key?(&1, "proposed_statements"))
    assert suitability["proposed_statements"] == %{"statement_1" => "The launch is on Friday."}

    round_check = Enum.find(states, &Map.has_key?(&1, "tool_calls"))
    assert round_check["condensed_workspace"] == "(empty)"
    assert [%{"tool" => _}] = round_check["tool_calls"]

    {pid, messages, _tools} = await_request!()
    request = text(messages)
    assert request =~ "- [s1] The launch is on Friday."
    assert request =~ "Advisory check: your recent work appears to establish or change facts"

    # The dashboard timeline sees both halves of the check: the transcript
    # read beside the tools, and the next activation waiting for the answer.
    settle_receive({:phase, %{phase: "cw_evidence", session_id: @first, duration_ms: read_ms}})
    settle_receive({:phase, %{phase: "cw_wait", session_id: @first, duration_ms: wait_ms}})
    assert read_ms >= 0 and wait_ms in 0..5_000
    # The tool result already holds revision 1, so the writer gets no copy.
    refute request =~ "Condensed Workspace, revision 1"

    SystemsRuntime.Proc.send(pid, {:cw_llm_response, end_turn("cw-end-1")})
    await_settled!(agent_id, @first)

    assert {:ok, %{revision: 1, statements: [%{"id" => "s1"}]}} =
             CondensedWorkspaces.get(group_id)

    # Another Session of the Group receives the full content at its round.
    deliver!(agent_id, @second, "src-2", "What is the launch date?")
    {pid, messages, _tools} = await_request!()
    request = text(messages)
    assert request =~ "Condensed Workspace, revision 1"
    assert request =~ "- [s1] The launch is on Friday."

    SystemsRuntime.Proc.send(pid, {:cw_llm_response, end_turn("cw-end-2")})
    await_settled!(agent_id, @second)
  end

  test "with the Group flag off, no content, tool or check is used", %{agent_id: agent_id} do
    deliver!(agent_id, @first, "src-off", "hello")

    {pid, messages, _tools} = await_request!()
    refute text(messages) =~ "Condensed Workspace"

    SystemsRuntime.Proc.send(pid, {:cw_llm_response, end_turn("cw-end-off")})
    await_settled!(agent_id, @first)
    settle_refute_receive({:decision_request, _, _, _}, 200)
  end

  defp await_decision! do
    settle_receive({:decision_request, _path, _auth, %{"state" => state}})
    state
  end

  defp end_turn(id),
    do: {:assistant, "", [%{id: id, name: "end_turn", args: %{"outcome" => "done"}}]}

  defp deliver!(agent_id, session_id, source_message_id, content) do
    assert {:ok, :created} =
             SalixAgent.deliver(
               agent_id,
               %{
                 content: content,
                 session_id: session_id,
                 role: "user",
                 created_at: SystemsClock.system_time(:second)
               },
               source_message_id: source_message_id
             )
  end

  defp await_request! do
    settle_receive({:cw_llm_request, pid, messages, tools})
    {pid, messages, tools}
  end

  defp text(messages) do
    Enum.map_join(messages, "\n", fn message ->
      case message[:content] || message["content"] do
        content when is_binary(content) -> content
        content -> inspect(content, limit: :infinity, printable_limit: :infinity)
      end
    end)
  end

  defp await_settled!(agent_id, session_id, attempts \\ 3000)
  defp await_settled!(_agent_id, _session_id, 0), do: flunk("session did not settle")

  defp await_settled!(agent_id, session_id, attempts) do
    :ok = SalixAgent.TestSupport.join_session_owner(agent_id, session_id)
    {:ok, session} = InternalSessionStore.read(agent_id, session_id)

    if InternalSession.last_ack_message_id(session) ==
         List.last(InternalSession.get(session, :messages)).id do
      session
    else
      SystemsClock.sleep(10)
      await_settled!(agent_id, session_id, attempts - 1)
    end
  end
end
