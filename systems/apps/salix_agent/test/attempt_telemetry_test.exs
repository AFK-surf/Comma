defmodule SalixAgent.AttemptTelemetryTest do
  use ExUnit.Case, async: false

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
      send(Application.fetch_env!(:salix_agent, :attempt_test_pid), {:attempt, fact})
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
    prev = Application.get_env(:salix_agent, :agent_observability_mod)
    Application.put_env(:salix_agent, :attempt_test_pid, self())

    on_exit(fn ->
      if prev,
        do: Application.put_env(:salix_agent, :agent_observability_mod, prev),
        else: Application.delete_env(:salix_agent, :agent_observability_mod)

      Application.delete_env(:salix_agent, :attempt_test_pid)
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

  test "classification names failures only by vocabulary words" do
    assert {"exception", nil, ""} = AttemptTelemetry.classify(%RuntimeError{message: "boom"})
    assert {"exit", nil, "timeout"} = AttemptTelemetry.classify({:exit, :timeout})

    assert {"exit", nil, "timeout"} =
             AttemptTelemetry.classify(
               {:exit, {:timeout, {GenServer, :call, [self(), :ping, 5_000]}}}
             )

    assert {"unknown", nil, ""} = AttemptTelemetry.classify(:odd)
    assert {"unknown", nil, ""} = AttemptTelemetry.classify({:error, %{}})

    assert {"transport_error", nil, "stream_idle_timeout"} =
             AttemptTelemetry.classify(
               {:error,
                %{
                  "category" => "transport_error",
                  "message" => "LLM provider transport failed",
                  "reason" => "{:stream_idle_timeout, 30000}"
                }}
             )

    assert {"transport_error", nil, "closed"} =
             AttemptTelemetry.classify(
               {:error,
                %{
                  "category" => "transport_error",
                  "reason" => ~s(%Mint.TransportError{reason: :closed})
                }}
             )

    assert {"permanent_provider_error", nil, "output_token_limit"} =
             AttemptTelemetry.classify(
               {:error,
                %{"category" => "permanent_provider_error", "reason" => "output_token_limit"}}
             )

    assert {"permanent_provider_error", nil, "incomplete"} =
             AttemptTelemetry.classify(
               {:error,
                %{
                  "category" => "permanent_provider_error",
                  "provider_status" => "incomplete",
                  "details" => ~s({"incomplete_details":{"reason":"max_output_tokens"}})
                }}
             )

    assert {"permanent_provider_error", 400, "INVALID_ARGUMENT"} =
             AttemptTelemetry.classify(
               {:error,
                %{
                  "category" => "permanent_provider_error",
                  "status" => 400,
                  "body" =>
                    ~s({"error":{"code":400,"status":"INVALID_ARGUMENT","message":"Request contains an invalid argument."}})
                }}
             )

    # An unlisted code is dropped, not recorded, however plausible it looks.
    assert {"retryable_provider_error", 503, ""} =
             AttemptTelemetry.classify(
               {:error,
                %{
                  "category" => "retryable_provider_error",
                  "status" => 503,
                  "body" => ~s({"error":{"type":"upstream_hiccup","code":"try_later"}})
                }}
             )

    assert {"unknown", nil, ""} =
             AttemptTelemetry.classify({:error, %{"category" => "something_new"}})
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

  test "an attempt killed at the job deadline carries what its stream had received" do
    progress = %{
      attempt: 2,
      attempt_started_at_ms: 1_789_372_800_000,
      elapsed_ms: 600_012,
      first_body_ms: 1_450,
      last_body_ms: 599_980,
      received_bytes: 48_213,
      received_chunks: 3_101,
      http_status: 200,
      first_content_ms: nil,
      last_content_ms: nil,
      content_deltas: 0
    }

    fact = AttemptTelemetry.build_killed(@meter_ctx, 6, {:dependency_timeout, :llm}, progress)

    assert fact.outcome == "killed"
    assert fact.attempt == 2
    assert fact.max_attempts == 6
    assert fact.category == "exit"
    assert fact.reason == "dependency_timeout"
    assert fact.duration_ms == 600_012
    assert fact.delay_ms == 0
    assert fact.started_at == ~U[2026-09-14 08:00:00.000Z]
    assert fact.http_status == 200
    assert fact.first_body_ms == 1_450
    assert fact.last_body_ms == 599_980
    assert fact.received_bytes == 48_213
    assert fact.received_chunks == 3_101
    assert fact.first_content_ms == nil
    assert fact.last_content_ms == nil
    assert fact.content_deltas == 0
    assert fact.source_key == "req-abc:2"

    for word <- String.split(fact.reason, " ", trim: true) do
      assert word in AttemptTelemetry.vocabulary()
    end

    # Killed before any attempt began: attempt 1, nothing observed, no
    # duration, and a crash reason keeps only its listed atoms.
    fact =
      AttemptTelemetry.build_killed(
        @meter_ctx,
        6,
        {:dependency_crashed, :llm, {:sk_test_SECRET, :killed}},
        nil
      )

    assert fact.outcome == "killed"
    assert fact.attempt == 1
    assert fact.reason == "dependency_crashed killed"
    assert fact.duration_ms == 0
    assert fact.http_status == nil
    assert fact.received_bytes == nil
    assert fact.content_deltas == nil
    refute inspect(fact) =~ "SECRET"

    Application.put_env(:salix_agent, :agent_observability_mod, Collector)

    assert :ok =
             AttemptTelemetry.emit_killed(@meter_ctx, 6, {:dependency_timeout, :llm}, progress)

    assert_receive {:attempt, %{outcome: "killed", received_chunks: 3_101}}
  end

  test "emit reaches a sink with the callback and is dropped by one without it" do
    Application.put_env(:salix_agent, :agent_observability_mod, Collector)

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

    assert_receive {:attempt, %{outcome: "exhausted", attempt: 1, http_status: 400}}

    Application.put_env(:salix_agent, :agent_observability_mod, LegacySink)

    assert :ok =
             AttemptTelemetry.emit(@meter_ctx, 1, 6, :retry, {:error, %{}}, 250, 5, nil)

    refute_receive {:attempt, _}, 50
  end
end
