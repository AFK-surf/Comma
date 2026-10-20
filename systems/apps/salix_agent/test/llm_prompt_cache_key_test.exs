defmodule SalixAgent.LLMPromptCacheKeyTest do
  @moduledoc """
  `SalixAgent.LLM` derives one stable provider prompt-cache key per session at
  the dispatch seam, so every caller (Round, compaction, titles, the judge)
  gets it without remembering to add one.
  """
  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle
  alias SalixAgent.LLM

  defmodule CapturingLLM do
    @behaviour SalixAgent.LLM

    @impl true
    def complete(_messages, _tools), do: record([])

    @impl true
    def complete(_messages, _tools, llm_opts), do: record(llm_opts)

    @impl true
    def complete_stream(_messages, _tools, _on_delta), do: record([])

    @impl true
    def complete_stream(_messages, _tools, _on_delta, llm_opts), do: record(llm_opts)

    defp record(opts) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.PersistentTerm.get({__MODULE__, :test_pid}),
        {:llm_called, opts}
      )

      {:final, "ok"}
    end
  end

  setup do
    prev_llm = SystemsRuntime.get_env(:salix_agent, :llm)
    SystemsRuntime.put_env(:salix_agent, :llm, CapturingLLM)
    SystemsRuntime.PersistentTerm.put({CapturingLLM, :test_pid}, SystemsRuntime.Proc.self())
    on_exit(fn -> SystemsRuntime.put_env(:salix_agent, :llm, prev_llm) end)
    :ok
  end

  @messages [%{"role" => "user", "content" => "hi"}]

  test "string-keyed template opts gain a string-keyed prompt_cache_key from the identity" do
    assert {:final, "ok"} =
             LLM.complete(@messages, [], %{"model" => "m", "provider" => "openai"},
               session_id: "ses1_1",
               agent_id: "a"
             )

    settle_receive({:llm_called, opts})
    assert opts["prompt_cache_key"] == LLM.prompt_cache_key("ses1_1")
    refute Map.has_key?(opts, :prompt_cache_key)
  end
end
