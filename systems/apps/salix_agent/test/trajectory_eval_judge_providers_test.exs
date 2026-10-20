defmodule SalixAgent.TrajectoryEval.JudgeProvidersTest do
  @moduledoc """
  The judge-model allowlist: dashboard options come from it, and a chosen key
  resolves to string-keyed llm_opts with the credential pulled server-side from
  api_key/api_key_env — never stored. A provider with no resolvable key fails
  closed so the caller skips rather than calling with an empty key.
  """
  use SystemsClock.Case, async: false

  alias SalixAgent.TrajectoryEval.JudgeProviders

  setup do
    prev = SystemsRuntime.get_env(:salix_agent, :trajectory_eval_judge_providers)

    on_exit(fn ->
      if prev,
        do: SystemsRuntime.put_env(:salix_agent, :trajectory_eval_judge_providers, prev),
        else: SystemsRuntime.delete_env(:salix_agent, :trajectory_eval_judge_providers)

      System.delete_env("JUDGE_TEST_LUNA_KEY")
    end)

    :ok
  end

  defp put_providers(map),
    do: SystemsRuntime.put_env(:salix_agent, :trajectory_eval_judge_providers, map)

  test "resolves a literal api_key entry to string-keyed llm_opts" do
    put_providers(%{
      "luna" => %{
        label: "GPT-5.6 Luna",
        protocol: "chat_completions",
        base_url: "https://gw.example/v1",
        model: "luna-x",
        max_tokens: 512,
        api_key: "sk-literal"
      }
    })

    assert {:ok, opts} = JudgeProviders.llm_opts("luna")

    assert opts == %{
             "model" => "luna-x",
             "protocol" => "chat_completions",
             "base_url" => "https://gw.example/v1",
             "api_key" => "sk-literal",
             "max_tokens" => 512
           }
  end

  test "a provider whose key can't be resolved fails closed" do
    put_providers(%{
      "luna" => %{
        label: "GPT-5.6 Luna",
        protocol: "chat_completions",
        model: "luna-x",
        api_key_env: "JUDGE_TEST_LUNA_KEY"
      }
    })

    # Env var not set → no key → skip signal, not an empty-key call.
    assert JudgeProviders.llm_opts("luna") == {:error, {:no_key, "luna"}}
  end

  # The shared missing/known/invalid contract that BOTH the Runner (paid-call
  # gate) and the dashboard (render state) resolve — exhaustive on the seams
  # where they historically diverged.
  test "resolve_selection keeps tenant absence, shadowing, and invalid sources straight" do
    put_providers(%{
      "haiku" => %{label: "Claude Haiku", protocol: "anthropic", model: "h", api_key: "k"}
    })

    # Nothing selected anywhere — nil and "" both read as absent.
    assert JudgeProviders.resolve_selection(nil, nil) == nil
    assert JudgeProviders.resolve_selection("", nil) == nil
    assert JudgeProviders.resolve_selection(nil, "") == nil

    # Known picks carry their source.
    assert JudgeProviders.resolve_selection("haiku", nil) == {:ok, "haiku", :tenant}
    assert JudgeProviders.resolve_selection(nil, "haiku") == {:ok, "haiku", :global}

    # An absent tenant value falls through to the global default — including
    # a persisted "" (how the dashboard spells "use the default").
    assert JudgeProviders.resolve_selection("", "haiku") == {:ok, "haiku", :global}
    assert JudgeProviders.resolve_selection("", "gone") == {:invalid, :global, "gone"}

    # Invalid selections name their source: a revoked tenant pick shadows even
    # a VALID global (no silent substitution), and a stale explicit global is
    # invalid, not absent.
    assert JudgeProviders.resolve_selection("gone", "haiku") == {:invalid, :tenant, "gone"}
    assert JudgeProviders.resolve_selection(nil, "gone") == {:invalid, :global, "gone"}
    assert JudgeProviders.resolve_selection(%{}, "haiku") == {:invalid, :tenant, %{}}
  end

  # The config.json → app-env lifecycle for revocation, end to end: what
  # ConfigJson emits is applied over a compiled allowlist, and the old provider
  # must stop resolving. Only an ABSENT judge_providers key preserves it.
  test "config.json revocation replaces a compiled allowlist" do
    alias SalixStore.ConfigJson

    apply_env = fn json ->
      put_providers(%{"old" => %{label: "Old", model: "o", api_key: "k"}})

      for {:salix_agent, :trajectory_eval_judge_providers = key, value} <-
            ConfigJson.app_env(json),
          do: SystemsRuntime.put_env(:salix_agent, key, value)
    end

    # Explicit empty map: the revocation statement.
    apply_env.(%{"trajectory_eval" => %{"judge_providers" => %{}}})
    refute JudgeProviders.known?("old")

    # Explicit malformed value: fails closed to empty, same outcome.
    apply_env.(%{"trajectory_eval" => %{"judge_providers" => ["revoked"]}})
    refute JudgeProviders.known?("old")

    # Absent key: not configured here — the compiled allowlist stands.
    apply_env.(%{"trajectory_eval" => %{"judge_enabled" => true}})
    assert JudgeProviders.known?("old")
  end
end
