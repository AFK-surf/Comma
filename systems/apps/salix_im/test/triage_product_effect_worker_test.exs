defmodule SalixIM.Triage.ProductEffectWorkerTest do
  use SystemsClock.Case, async: true

  alias SalixIM.Triage.{AuditSink, ProductEffectWorker}

  test "the local rehearsal captures reply intent with zero external writes" do
    claim = claim("reply", 1)
    parent = SystemsRuntime.Proc.self()

    claim_fun = fn "local-pod", opts ->
      SystemsRuntime.Proc.send(parent, {:claim_opts, opts})
      {:ok, [claim]}
    end

    settle_fun = fn ^claim, effect ->
      SystemsRuntime.Proc.send(parent, {:settled_effect, effect})
      {:ok, %{status: :settled, state: :applied, result: %{}}}
    end

    assert {:ok, %{claimed: 1, applied: 1}} =
             ProductEffectWorker.process_once(
               adapter: AuditSink,
               holder: "local-pod",
               claim_fun: claim_fun,
               settle_fun: settle_fun
             )

    assert_receive {:claim_opts, [limit: 5, lease_ms: 30_000]}

    assert_receive {:settled_effect,
                    %{
                      adapter: :audit_sink,
                      outcome: :applied,
                      external_writes: 0,
                      communication: %{
                        "kind" => "reply",
                        "status" => "captured",
                        "text" => "Please confirm the owner."
                      }
                    }}
  end

  test "a local-completion retry audits the provider write that already happened" do
    claim = claim("reply", 1)

    assert {:ok, %{claimed: 1, retried: 1}} =
             ProductEffectWorker.process_once(
               adapter: __MODULE__.CompletionFailingAdapter,
               holder: "pod-a",
               claim_fun: fn _holder, _opts -> {:ok, [claim]} end,
               settle_fun: fn ^claim, effect ->
                 SystemsRuntime.Proc.send(
                   SystemsRuntime.Proc.self(),
                   {:completion_retry_effect, effect}
                 )

                 {:ok, %{status: :settled, state: :pending}}
               end
             )

    assert_receive {:completion_retry_effect,
                    %{outcome: :failed, retry: true, external_writes: 1}}
  end

  test "a retryable delegation failure cannot settle the obligation as applied" do
    claim =
      put_in(claim("silence", 1).payload["delegations"], [
        %{"task" => "Inspect the rollout", "source_refs" => ["slack://T/C/1/2"]}
      ])

    settle_fun = fn ^claim, effect ->
      SystemsRuntime.Proc.send(SystemsRuntime.Proc.self(), {:settled_delegation_effect, effect})
      {:ok, %{status: :settled, state: if(effect.retry, do: :pending, else: :failed)}}
    end

    assert {:ok, %{claimed: 1, retried: 1, applied: 0}} =
             ProductEffectWorker.process_once(
               adapter: AuditSink,
               delegation_effect: __MODULE__.RetryableDelegationEffect,
               holder: "pod-a",
               claim_fun: fn _holder, _opts -> {:ok, [claim]} end,
               settle_fun: settle_fun
             )

    assert_receive {:settled_delegation_effect,
                    %{
                      outcome: :failed,
                      retry: true,
                      metadata: %{
                        "delegation_error" => "task_create_unavailable",
                        "delegations" => [%{"status" => "retry_scheduled"}]
                      }
                    }}
  end

  defmodule FailingAdapter do
    @behaviour SalixIM.Triage.ProductEffectAdapter
    @impl true
    def apply(_claim, _opts), do: {:error, :source_unavailable, true}
  end

  defmodule CompletionFailingAdapter do
    @behaviour SalixIM.Triage.ProductEffectAdapter
    @impl true
    def apply(_claim, _opts),
      do: {:error, :triage_subscription_unavailable, true, 1}
  end

  defmodule RetryableDelegationEffect do
    def apply(_claim, _opts),
      do:
        {:error, :task_create_unavailable, true, [%{"index" => 0, "status" => "retry_scheduled"}]}
  end

  defp claim(kind, attempt) do
    %{
      namespace_key: String.duplicate("a", 64),
      run_id: "run-1",
      obligation_id: "triage-product-" <> String.duplicate("b", 64),
      attempt: attempt,
      claim_token: "claim-1",
      holder: "local-pod",
      lease_until: SystemsClock.utc_now(),
      payload: %{
        "target" => %{"channel_id" => "C1", "thread_ts" => "100.000001"},
        "communication" => communication(kind),
        "delegations" => []
      }
    }
  end

  defp communication("reply") do
    %{
      "kind" => "reply",
      "text" => "Please confirm the owner.",
      "source_refs" => ["slack://T1/C1/100.000001"]
    }
  end

  defp communication("reaction") do
    %{
      "kind" => "reaction",
      "emoji" => "tada",
      "source_refs" => ["slack://T1/C1/100.000001"]
    }
  end

  defp communication("silence"),
    do: %{"kind" => "silence", "reason" => "already_answered", "source_refs" => []}
end
