defmodule SalixIM.Triage.DelegationEffectTest do
  use ExUnit.Case, async: true

  alias SalixIM.Triage.DelegationEffect

  test "prepares between two freshness checks and admits one exact Router handoff" do
    claim = claim()

    assert {:ok,
            [
              %{
                "index" => 0,
                "status" => "routed",
                "source_count" => 1
              }
            ]} =
             DelegationEffect.apply(claim,
               freshness_port: __MODULE__.Fresh,
               delegation_port: __MODULE__.DelegationPort,
               port_opts: [test_pid: self()]
             )

    assert_receive {:freshness_check, ^claim}

    assert_receive {:delegation_prepare, ^claim, %{"task" => "Inspect the rollout"},
                    "triage-delegation:obligation-1:0"}

    assert_receive {:freshness_check, ^claim}
    assert_receive {:delegation_commit, "triage-delegation:obligation-1:0"}
  end

  test "a changed authority after preparation suppresses creation" do
    claim = claim()

    assert {:ok,
            [
              %{
                "status" => "suppressed_stale",
                "reason" => "authority_changed_during_prepare"
              }
            ]} =
             DelegationEffect.apply(claim,
               freshness_port: __MODULE__.ChangingFreshness,
               delegation_port: __MODULE__.DelegationPort,
               port_opts: [test_pid: self()]
             )

    refute_receive {:delegation_commit, _request_id}
  end

  test "a retryable Task error remains unsettled for idempotent retry" do
    claim = claim()

    assert {:error, :task_create_unavailable, true,
            [%{"status" => "retry_scheduled", "index" => 0}]} =
             DelegationEffect.apply(claim,
               freshness_port: __MODULE__.Fresh,
               delegation_port: __MODULE__.RetryableDelegationPort,
               port_opts: [test_pid: self()]
             )
  end

  test "Router admission is routed, not a canonical Task creation receipt" do
    assert {:ok, [%{"status" => "routed", "index" => 0} = result]} =
             DelegationEffect.apply(claim(),
               freshness_port: __MODULE__.Fresh,
               delegation_port: __MODULE__.RouterAdmissionPort,
               port_opts: [test_pid: self()]
             )

    refute Map.has_key?(result, "conversation_id")
  end

  defmodule RouterAdmissionPort do
    def prepare(_claim, _delegation, request_id), do: {:ok, request_id}
    def commit(request_id), do: {:ok, %{"disposition" => "routed", "request_id" => request_id}}
  end

  defmodule Fresh do
    def check(claim, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:freshness_check, claim})
      {:ok, %{status: :fresh, authority_ref: :same}}
    end
  end

  defmodule ChangingFreshness do
    def check(claim, opts) do
      pid = Keyword.fetch!(opts, :test_pid)
      send(pid, {:freshness_check, claim})
      count = Process.get({__MODULE__, :count}, 0) + 1
      Process.put({__MODULE__, :count}, count)
      {:ok, %{status: :fresh, authority_ref: count}}
    end
  end

  defmodule DelegationPort do
    def prepare(claim, delegation, request_id) do
      pid = Process.get(:delegation_test_pid)
      send(pid, {:delegation_prepare, claim, delegation, request_id})
      {:ok, %{request_id: request_id, test_pid: pid}}
    end

    def commit(%{request_id: request_id, test_pid: pid}) do
      send(pid, {:delegation_commit, request_id})
      {:ok, %{"disposition" => "routed", "request_id" => request_id}}
    end
  end

  defmodule RetryableDelegationPort do
    def prepare(_claim, _delegation, request_id),
      do: {:ok, %{request_id: request_id}}

    def commit(_prepared), do: {:error, :task_create_unavailable, true}
  end

  setup do
    Process.put(:delegation_test_pid, self())
    Process.delete({__MODULE__.ChangingFreshness, :count})
    :ok
  end

  defp claim do
    %{
      obligation_id: "obligation-1",
      payload: %{
        "delegations" => [
          %{"task" => "Inspect the rollout", "source_refs" => ["slack://T/C/1/2"]}
        ]
      }
    }
  end
end
