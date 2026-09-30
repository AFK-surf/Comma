defmodule SalixAgent.LLMPromptCacheKeyTest do
  @moduledoc """
  `SalixAgent.LLM` derives one stable provider prompt-cache key per session at
  the dispatch seam, so every caller (Round, compaction, titles, the judge)
  gets it without remembering to add one.
  """
  use ExUnit.Case, async: false

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
      send(:persistent_term.get({__MODULE__, :test_pid}), {:llm_called, opts})
      {:final, "ok"}
    end
  end

  setup do
    prev_llm = Application.get_env(:salix_agent, :llm)
    Application.put_env(:salix_agent, :llm, CapturingLLM)
    :persistent_term.put({CapturingLLM, :test_pid}, self())
    on_exit(fn -> Application.put_env(:salix_agent, :llm, prev_llm) end)
    :ok
  end

  @messages [%{"role" => "user", "content" => "hi"}]

  test "the key is a UUID v5 of the session id: stable per session, distinct across sessions" do
    key = LLM.prompt_cache_key("ses1_2098930008159420416")

    assert key =~ ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
    assert key == LLM.prompt_cache_key("ses1_2098930008159420416")
    refute key == LLM.prompt_cache_key("ses1_2098930008159420417")
  end

  test "string-keyed template opts gain a string-keyed prompt_cache_key from the identity" do
    assert {:final, "ok"} =
             LLM.complete(@messages, [], %{"model" => "m", "provider" => "openai"},
               session_id: "ses1_1",
               agent_id: "a"
             )

    assert_receive {:llm_called, opts}
    assert opts["prompt_cache_key"] == LLM.prompt_cache_key("ses1_1")
    refute Map.has_key?(opts, :prompt_cache_key)
  end

  test "keyword opts and streaming dispatch carry the key too" do
    on_delta = fn _ -> :ok end

    assert {:final, "ok"} =
             LLM.complete_stream(@messages, [], on_delta, [model: "m", provider: "openai"],
               session_id: "ses1_2"
             )

    assert_receive {:llm_called, opts}
    assert Keyword.get(opts, :prompt_cache_key) == LLM.prompt_cache_key("ses1_2")
  end

  test "only OpenAI providers get a key: Gemini, DeepSeek and untagged opts stay untouched" do
    for opts <- [
          %{"model" => "google/gemini-3.8-flash", "provider" => "gemini"},
          %{"model" => "deepseek-flash", "provider" => "deepseek"},
          %{"model" => "claude-opus-5", "provider" => "anthropic"},
          %{"model" => "m"}
        ] do
      assert {:final, "ok"} = LLM.complete(@messages, [], opts, session_id: "ses1_9")
      assert_receive {:llm_called, called}
      assert called == opts
    end
  end

  test "no session identity means no key, and an explicit key is kept" do
    assert {:final, "ok"} = LLM.complete(@messages, [], %{"model" => "m", "provider" => "openai"})
    assert_receive {:llm_called, opts}
    refute Map.has_key?(opts, "prompt_cache_key")

    assert {:final, "ok"} =
             LLM.complete(
               @messages,
               [],
               %{"model" => "m", "provider" => "openai", "prompt_cache_key" => "fixed"},
               session_id: "ses1_3"
             )

    assert_receive {:llm_called, opts}
    assert opts["prompt_cache_key"] == "fixed"
  end
end
