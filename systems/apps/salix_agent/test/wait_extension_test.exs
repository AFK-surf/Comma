defmodule SalixAgent.WaitExtensionTest do
  use SystemsClock.Case, async: false

  alias SalixAgent.{InternalSession, WaitExtension}

  defmodule Probe do
    @behaviour SalixAgent.WaitExtension

    @impl true
    def delegates_busy?(_agent, _session, _wait) do
      case SystemsRuntime.get_env(:salix_agent, :wait_extension_test_answer) do
        :raise -> raise "probe exploded"
        answer -> answer
      end
    end
  end

  setup do
    prev_mod = SystemsRuntime.get_env(:salix_agent, :wait_extension_mod)
    prev_cap = SystemsRuntime.get_env(:salix_agent, :wait_for_extension_ceiling_seconds)
    SystemsRuntime.put_env(:salix_agent, :wait_extension_mod, Probe)
    SystemsRuntime.delete_env(:salix_agent, :wait_for_extension_ceiling_seconds)

    on_exit(fn ->
      if prev_mod,
        do: SystemsRuntime.put_env(:salix_agent, :wait_extension_mod, prev_mod),
        else: SystemsRuntime.delete_env(:salix_agent, :wait_extension_mod)

      if prev_cap,
        do: SystemsRuntime.put_env(:salix_agent, :wait_for_extension_ceiling_seconds, prev_cap),
        else: SystemsRuntime.delete_env(:salix_agent, :wait_for_extension_ceiling_seconds)

      SystemsRuntime.delete_env(:salix_agent, :wait_extension_test_answer)
    end)

    :ok
  end

  @wait %{
    "wait_id" => "wait-abc",
    "reason" => "worker report",
    "timeout_seconds" => 300,
    "deadline_ms" => 1_789_372_700_000,
    "source" => "wait_for"
  }

  test "a busy Worker re-arms the wait for the same duration under a fresh identity" do
    SystemsRuntime.put_env(:salix_agent, :wait_extension_test_answer, true)
    before = SystemsClock.system_time(:millisecond)
    assert {:extend, wait} = decide(@wait)
    # A new id per extension: a stale timer for the old deadline no longer
    # matches, and two deadlines in one minute never share a timer key.
    assert wait["wait_id"] == "wait-abc-x1"
    assert wait["extended_from"] == "wait-abc"
    assert (wait["deadline_ms"] - before) in 300_000..301_000
    assert wait["timeout_seconds"] == 300
    assert wait["extensions"] == 1
    assert wait["extended_ms"] == 300_000
    assert {:extend, again} = decide(wait)
    assert again["wait_id"] == "wait-abc-x2"
    assert again["extended_from"] == "wait-abc"
    assert again["extensions"] == 2
    assert again["extended_ms"] == 600_000
  end

  # The kernel's loop decides an expired wait during activation; the probe
  # answers its busy-delegate question.
  defp decide(wait) do
    session =
      InternalSession.new("agt1_a", "ses1_s")
      |> InternalSession.apply_events([
        %{"type" => "wait_set", "session_id" => "ses1_s", "wait" => %{wait | "deadline_ms" => 1}}
      ])

    step(session, nil, {:activate, InternalSession.activation_facts()})
  end

  defp step(session, machine, event) do
    case InternalSession.query(session, :loop_step, {machine, event}) do
      {next, [{:fact, {:delegates_busy, wait}}]} ->
        step(session, next, {:fact, WaitExtension.busy?("agt1_a", "ses1_s", wait)})

      {_next, [{:commit, [%{"type" => "wait_set", "wait" => wait}], _, _} | _]} ->
        {:extend, wait}

      {_next, [{:materialize, :expire}]} ->
        :wake
    end
  end
end
