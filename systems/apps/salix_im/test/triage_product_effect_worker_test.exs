defmodule SalixIM.Triage.ProductEffectWorkerTest do
  use ExUnit.Case, async: true

  alias SalixIM.Triage.{AuditSink, ProductEffectWorker}

  test "the local rehearsal captures reply intent with zero external writes" do
    claim = claim("reply", 1)
    parent = self()

    claim_fun = fn "local-pod", opts ->
      send(parent, {:claim_opts, opts})
      {:ok, [claim]}
    end

    settle_fun = fn ^claim, effect ->
      send(parent, {:settled_effect, effect})
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

  test "the local rehearsal captures reaction intent with zero external writes" do
    claim = claim("reaction", 1)

    assert {:ok, %{claimed: 1, applied: 1}} =
             ProductEffectWorker.process_once(
               adapter: AuditSink,
               holder: "local-pod",
               claim_fun: fn _holder, _opts -> {:ok, [claim]} end,
               settle_fun: fn ^claim, effect ->
                 send(self(), {:settled_reaction_effect, effect})
                 {:ok, %{status: :settled, state: :applied, result: %{}}}
               end
             )

    assert_receive {:settled_reaction_effect,
                    %{
                      external_writes: 0,
                      communication: %{
                        "kind" => "reaction",
                        "emoji" => "tada",
                        "status" => "captured"
                      }
                    }}
  end

  test "a companion reaction failure does not roll back an applied reply" do
    reply_claim = claim("reply", 1)

    reaction_claim =
      claim("reaction", 1)
      |> Map.put(:obligation_id, "triage-product-" <> String.duplicate("c", 64))

    parent = self()

    assert {:ok, %{claimed: 1, applied: 1}} =
             ProductEffectWorker.process_once(
               adapter: AuditSink,
               holder: "reply-pod",
               claim_fun: fn "reply-pod", _opts -> {:ok, [reply_claim]} end,
               settle_fun: fn ^reply_claim, effect ->
                 send(parent, {:primary_settled, effect.outcome})
                 {:ok, %{status: :settled, state: :applied, result: %{}}}
               end
             )

    assert {:ok, %{claimed: 1, retried: 1, applied: 0}} =
             ProductEffectWorker.process_once(
               adapter: __MODULE__.FailingAdapter,
               holder: "reaction-pod",
               claim_fun: fn "reaction-pod", _opts -> {:ok, [reaction_claim]} end,
               settle_fun: fn ^reaction_claim, effect ->
                 send(parent, {:companion_settled, effect.outcome, effect.retry})
                 {:ok, %{status: :settled, state: :pending, result: %{}}}
               end
             )

    assert_receive {:primary_settled, :applied}
    assert_receive {:companion_settled, :failed, true}
  end

  test "retryable failures stop retrying at the bounded attempt limit" do
    parent = self()

    for {attempt, expected_retry} <- [{2, true}, {3, false}] do
      claim = claim("reply", attempt)

      settle_fun = fn ^claim, effect ->
        send(parent, {:attempt_effect, attempt, effect})
        {:ok, %{status: :settled, state: if(effect.retry, do: :pending, else: :failed)}}
      end

      assert {:ok, %{claimed: 1}} =
               ProductEffectWorker.process_once(
                 adapter: __MODULE__.FailingAdapter,
                 holder: "pod-a",
                 claim_fun: fn _holder, _opts -> {:ok, [claim]} end,
                 settle_fun: settle_fun,
                 max_attempts: 3
               )

      assert_receive {:attempt_effect, ^attempt,
                      %{outcome: :failed, retry: ^expected_retry, external_writes: 0}}
    end
  end

  test "a local-completion retry audits the provider write that already happened" do
    claim = claim("reply", 1)

    assert {:ok, %{claimed: 1, retried: 1}} =
             ProductEffectWorker.process_once(
               adapter: __MODULE__.CompletionFailingAdapter,
               holder: "pod-a",
               claim_fun: fn _holder, _opts -> {:ok, [claim]} end,
               settle_fun: fn ^claim, effect ->
                 send(self(), {:completion_retry_effect, effect})
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
      send(self(), {:settled_delegation_effect, effect})
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
      lease_until: DateTime.utc_now(),
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
