defmodule SalixAgent.AttemptTelemetryTest do
  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle
  alias SalixAgent.AttemptTelemetry

  defmodule Collector do
    @moduledoc false
    @behaviour SalixAgent.Observability

    @impl true
    def tool_call(_fact), do: :ok

    @impl true
    def agent_run(_fact), do: :ok

    @impl true
    def llm_attempt(fact) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_agent, :attempt_test_pid),
        {:attempt, fact}
      )

      :ok
    end
  end

  # A sink from before the callback existed: attempt facts must be dropped,
  # not raise.
  defmodule LegacySink do
    @moduledoc false
    def tool_call(_fact), do: :ok
    def agent_run(_fact), do: :ok
  end

  @meter_ctx %{
    agent_id: "ag-1",
    salix_agent_id: "ag-1",
    session_id: "ses-1",
    tenant_id: "t1",
    group_id: "g1",
    round_id: "round-abc",
    request_id: "req-abc",
    trace_id: "trace-abc",
    provider: "anthropic",
    model: "claude-opus-5",
    app_revision: "rev-1",
    actor_type: "user",
    billing_context: %{"surface" => "comma"}
  }

  # Only these characters may ever reach the `reason` column.
  @summary_alphabet ~r/\A[A-Za-z0-9_.:\- ]*\z/

  setup do
    prev = SystemsRuntime.get_env(:salix_agent, :agent_observability_mod)
    SystemsRuntime.put_env(:salix_agent, :attempt_test_pid, SystemsRuntime.Proc.self())

    on_exit(fn ->
      if prev,
        do: SystemsRuntime.put_env(:salix_agent, :agent_observability_mod, prev),
        else: SystemsRuntime.delete_env(:salix_agent, :agent_observability_mod)

      SystemsRuntime.delete_env(:salix_agent, :attempt_test_pid)
    end)

    :ok
  end

  test "a provider error fact carries the attempt, its outcome, class, status and error codes" do
    error =
      {:error,
       %{
         "category" => "retryable_provider_error",
         "message" => "LLM provider returned HTTP 429",
         "status" => 429,
         "body" =>
           ~s({"error":{"type":"rate_limit_error","code":"rate_limit_exceeded","message":"Rate limit reached for org-123 on requests per min. Please try again in 20s."}}),
         "retryable" => true
       }}

    fact =
      AttemptTelemetry.build(@meter_ctx, 2, 6, :retry, error, 10_000, 9_800, 1_789_372_800_000)

    assert fact.source == "salix_agent.llm_attempt"
    assert fact.source_key == "req-abc:2"
    assert fact.entrypoint == "llm_attempt"
    assert fact.surface == "comma"
    assert fact.attempt == 2
    assert fact.max_attempts == 6
    assert fact.outcome == "retry"
    assert fact.category == "retryable_provider_error"
    assert fact.http_status == 429
    assert fact.reason == "rate_limit_error rate_limit_exceeded"
    assert fact.duration_ms == 9_800
    assert fact.delay_ms == 10_000
    assert fact.started_at == ~U[2026-09-14 08:00:00.000Z]
    assert fact.provider == "anthropic"
    assert fact.model == "claude-opus-5"
    assert fact.round_id == "round-abc"
    assert fact.charge_status == "unattributed"
  end

  test "provider bodies, messages, exception text and exit values never reach the fact" do
    secrets = [
      "sk-live-4f8a2c9e1b7d6a3f0e5c8b2a9d1f4e7c",
      "Bearer eyJhbGciOiJIUzI1NiJ9.c2VjcmV0.c2ln",
      "ya29.a0AfH6SMB-google-oauth-token",
      "https://user:hunter2@proxy.internal/v1"
    ]

    [key, bearer, oauth, url] = secrets

    reasons = [
      # A JSON body whose message echoes the key, as OpenAI-compatible
      # endpoints do for "Incorrect API key provided".
      {:error,
       %{
         "category" => "permanent_provider_error",
         "status" => 401,
         "message" => "LLM provider returned HTTP 401",
         "body" =>
           ~s({"error":{"type":"invalid_request_error","code":"invalid_api_key","message":"Incorrect API key provided: #{key}."}})
       }},
      # A body that is not JSON at all.
      {:error,
       %{
         "category" => "retryable_provider_error",
         "status" => 502,
         "body" => "upstream rejected #{bearer} for #{url}"
       }},
      # Identifier-shaped secrets under prose keys are still not read.
      {:error,
       %{
         "category" => "permanent_provider_error",
         "status" => 403,
         "body" => ~s({"error":{"message":"#{oauth}","param":"#{key}"}})
       }},
      # A transport reason whose strings carry the URL and token.
      {:error,
       %{
         "category" => "transport_error",
         "reason" => ~s({:econnrefused, "#{url}", %{"authorization" => "#{bearer}"}})
       }},
      # A provider-state failure with details.
      {:error,
       %{
         "category" => "permanent_provider_error",
         "provider_status" => "failed",
         "details" => ~s({"error":{"message":"token #{oauth} expired"}})
       }},
      # An exception whose message carries the key.
      %RuntimeError{message: "auth failed for #{key}"},
      %ArgumentError{message: bearer},
      # Caught exits with the secret inside strings, maps and charlists.
      {:exit, {:shutdown, "lost #{oauth}"}},
      {:exit, {%{"token" => bearer}, [key]}},
      {:throw, ~c"#{key}"},
      # Values the loop should never see, but which must not leak either.
      key,
      {:unexpected, bearer},
      # Identifier-shaped secrets in the kernel's own fields.
      {:error, %{"category" => "permanent_provider_error", "reason" => "sk-test-SECRET"}},
      {:error,
       %{"category" => "permanent_provider_error", "provider_status" => "sk_test_SECRET"}},
      {:error,
       %{
         "category" => "retryable_provider_error",
         "status" => 429,
         "body" =>
           ~s({"error":{"type":"sk_test_SECRET","code":"sk-test-SECRET","status":"SK_TEST_SECRET"}})
       }},
      # A transport preview truncated before its closing quote, so the atom-
      # shaped text inside the string is no longer visibly a string.
      {:error,
       %{
         "category" => "transport_error",
         "reason" => ~s({:error, "authorization :sk_test_SECRET timeout)
       }},
      # Exit values whose atoms are not listed.
      {:exit, {:sk_test_SECRET, :timeout}},
      {:exit, %{token: :sk_test_SECRET}}
    ]

    vocabulary = AttemptTelemetry.vocabulary()

    for reason <- reasons do
      fact = AttemptTelemetry.build(@meter_ctx, 1, 6, :retry, reason, 250, 5, nil)
      rendered = inspect(fact, limit: :infinity, printable_limit: :infinity)

      for secret <- secrets do
        refute rendered =~ secret,
               "#{inspect(secret)} leaked from #{inspect(reason, limit: 5)}"
      end

      refute rendered =~ "hunter2"
      refute rendered =~ "Incorrect API key"
      refute rendered =~ ~r/SECRET/i
      assert Regex.match?(@summary_alphabet, fact.reason), fact.reason

      for word <- String.split(fact.reason, " ", trim: true) do
        assert word in vocabulary, "#{word} is not a vocabulary word"
      end
    end
  end

  test "emit reaches a sink with the callback and is dropped by one without it" do
    SystemsRuntime.put_env(:salix_agent, :agent_observability_mod, Collector)

    assert :ok =
             AttemptTelemetry.emit(
               @meter_ctx,
               1,
               6,
               :exhausted,
               {:error, %{"category" => "permanent_provider_error", "status" => 400}},
               0,
               120,
               1_789_372_800_000
             )

    settle_receive({:attempt, %{outcome: "exhausted", attempt: 1, http_status: 400}})
    SystemsRuntime.put_env(:salix_agent, :agent_observability_mod, LegacySink)

    assert :ok =
             AttemptTelemetry.emit(@meter_ctx, 1, 6, :retry, {:error, %{}}, 250, 5, nil)

    settle_refute_receive({:attempt, _}, 50)
  end
end
