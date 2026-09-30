defmodule SalixAgent.LLMRequestTimeoutE2ETest do
  use ExUnit.Case, async: false

  alias SalixAgent.{DependencyJob, LLM}

  setup do
    previous_request_timeout = Application.get_env(:salix_agent, :llm_request_timeout_ms)
    previous_dependency_timeouts = Application.get_env(:salix_agent, :dependency_job_timeout_ms)

    Application.delete_env(:salix_agent, :llm_request_timeout_ms)
    Application.delete_env(:salix_agent, :dependency_job_timeout_ms)

    on_exit(fn ->
      restore_env(:llm_request_timeout_ms, previous_request_timeout)
      restore_env(:dependency_job_timeout_ms, previous_dependency_timeouts)
    end)

    :ok
  end

  test "the default agent-owned LLM chain has one ten-minute deadline" do
    assert LLM.request_timeout_ms() == 600_000

    for kind <- [:llm, :compaction] do
      assert DependencyJob.timeout_ms(kind) == 600_000

      assert {:ok, job} =
               DependencyJob.start(kind, "timeout-contract-#{kind}", fn ->
                 Process.sleep(:infinity)
               end)

      assert job.timeout_ms == 600_000
      :ok = DependencyJob.cancel(job)
    end

    assert DependencyJob.timeout_ms(:tool) == 120_000
    assert DependencyJob.timeout_ms(:external_runtime) == 120_000
  end

  test "streamed responses are watched for stalls well inside that deadline" do
    for key <- [:llm_stream_idle_timeout_ms, :llm_stream_first_event_timeout_ms] do
      Application.delete_env(:salix_agent, key)
    end

    assert LLM.stream_idle_timeout_ms() == 30_000
    assert LLM.stream_first_event_timeout_ms() == 120_000

    Application.put_env(:salix_agent, :llm_stream_idle_timeout_ms, 5_000)
    Application.put_env(:salix_agent, :llm_stream_first_event_timeout_ms, :infinity)
    assert LLM.stream_idle_timeout_ms() == 5_000
    assert LLM.stream_first_event_timeout_ms() == :infinity

    # Invalid values fall back to the defaults rather than disabling the check.
    Application.put_env(:salix_agent, :llm_stream_idle_timeout_ms, 0)
    Application.put_env(:salix_agent, :llm_stream_first_event_timeout_ms, "later")
    assert LLM.stream_idle_timeout_ms() == 30_000
    assert LLM.stream_first_event_timeout_ms() == 120_000

    for key <- [:llm_stream_idle_timeout_ms, :llm_stream_first_event_timeout_ms] do
      Application.delete_env(:salix_agent, key)
    end
  end

  test "a reduced request timeout reaches both LLM dependency watchdogs" do
    Application.put_env(:salix_agent, :llm_request_timeout_ms, 20)

    for kind <- [:llm, :compaction] do
      assert {:ok, job} =
               DependencyJob.start(kind, "timeout-override-#{kind}", fn ->
                 Process.sleep(:infinity)
               end)

      assert job.timeout_ms == 20
      assert_receive {:dependency_job_timeout, token}, 500
      assert token == job.token
      :ok = DependencyJob.cancel(job, :timeout)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:salix_agent, key)
  defp restore_env(key, value), do: Application.put_env(:salix_agent, key, value)
end
