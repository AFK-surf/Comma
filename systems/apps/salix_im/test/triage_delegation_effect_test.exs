defmodule SalixIM.Triage.DelegationEffectTest do
  use SystemsClock.Case, async: true

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
               port_opts: [test_pid: SystemsRuntime.Proc.self()]
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
               port_opts: [test_pid: SystemsRuntime.Proc.self()]
             )

    refute_receive {:delegation_commit, _request_id}
  end

  test "unanchored persisted delegations suppress in place without shifting sibling ordinals" do
    claim = %{
      obligation_id: "obligation-ordinal",
      payload: %{
        "delegations" => [
          %{
            "task" => "Stale unrelated login follow-up",
            "source_refs" => ["triage-context://other-thread"]
          },
          %{
            "task" => "Anchored current thread investigation",
            "source_refs" => ["slack://T/C/1/2"]
          }
        ]
      }
    }

    assert {:ok,
            [
              %{
                "index" => 0,
                "status" => "suppressed_stale",
                "reason" => "unanchored_delegation"
              },
              %{
                "index" => 1,
                "status" => "routed",
                "source_count" => 1
              }
            ]} =
             DelegationEffect.apply(claim,
               freshness_port: __MODULE__.Fresh,
               delegation_port: __MODULE__.DelegationPort,
               port_opts: [test_pid: SystemsRuntime.Proc.self()]
             )

    assert_received {:delegation_prepare, ^claim,
                     %{"task" => "Anchored current thread investigation"},
                     "triage-delegation:obligation-ordinal:1"}

    assert_received {:delegation_commit, "triage-delegation:obligation-ordinal:1"}

    # Scheduled recheck delegations anchored by payload.recheck_context_refs remain allowed.
    recheck_claim = %{
      obligation_id: "obligation-recheck",
      payload: %{
        "recheck_context_refs" => ["triage-context://due-reminder"],
        "delegations" => [
          %{
            "task" => "Recheck due reminder",
            "source_refs" => ["triage-context://due-reminder"]
          }
        ]
      }
    }

    assert {:ok, [%{"index" => 0, "status" => "routed"}]} =
             DelegationEffect.apply(recheck_claim,
               freshness_port: __MODULE__.Fresh,
               delegation_port: __MODULE__.DelegationPort,
               port_opts: [test_pid: SystemsRuntime.Proc.self()]
             )
  end

  test "historical ChannelBatch obligations suppress sibling-thread slack refs in place without shifting ordinals" do
    claim = %{
      obligation_id: "obligation-channel-batch",
      payload: %{
        "target" => %{
          "workspace_id" => "T1",
          "channel_id" => "C1",
          "thread_ts" => "1700000001.000100"
        },
        "source_messages" => [
          %{"message_ts" => "1700000001.000100"},
          %{"message_ts" => "1700000001.000105"},
          %{"message_ts" => "1700000002.000205"}
        ],
        "delegations" => [
          %{
            "task" => "Sibling thread channel-scoped delegation",
            "source_refs" => ["slack://T1/C1/channel/1700000002.000205"]
          },
          %{
            "task" => "Sibling thread thread-scoped delegation",
            "source_refs" => ["slack://T1/C1/1700000002.000200/1700000002.000205"]
          },
          %{
            "task" => "Anchored target thread channel-scoped delegation",
            "source_refs" => ["slack://T1/C1/channel/1700000001.000105"]
          }
        ]
      }
    }

    assert {:ok,
            [
              %{
                "index" => 0,
                "status" => "suppressed_stale",
                "reason" => "unanchored_delegation"
              },
              %{
                "index" => 1,
                "status" => "suppressed_stale",
                "reason" => "unanchored_delegation"
              },
              %{
                "index" => 2,
                "status" => "routed",
                "source_count" => 1
              }
            ]} =
             DelegationEffect.apply(claim,
               freshness_port: __MODULE__.FreshWithRoots,
               delegation_port: __MODULE__.DelegationPort,
               port_opts: [
                 test_pid: SystemsRuntime.Proc.self(),
                 message_roots: %{
                   "1700000001.000100" => "1700000001.000100",
                   "1700000001.000105" => "1700000001.000100",
                   "1700000002.000200" => "1700000002.000200",
                   "1700000002.000205" => "1700000002.000200"
                 }
               ]
             )

    assert_received {:delegation_prepare, ^claim,
                     %{"task" => "Anchored target thread channel-scoped delegation"},
                     "triage-delegation:obligation-channel-batch:2"}

    assert_received {:delegation_commit, "triage-delegation:obligation-channel-batch:2"}
  end

  test "pre-deploy historical ChannelBatch obligations without persisted root_thread_ts resolve thread roots from freshness check before prepare" do
    claim = %{
      obligation_id: "obligation-legacy-channel",
      payload: %{
        "target" => %{
          "workspace_id" => "T1",
          "channel_id" => "C1",
          "thread_ts" => "1700000001.000100"
        },
        "source_messages" => [
          %{"message_ts" => "1700000001.000105"},
          %{"message_ts" => "1700000002.000205"}
        ],
        "delegations" => [
          %{
            "task" => "Sibling reply without persisted root_thread_ts",
            "source_refs" => ["slack://T1/C1/channel/1700000002.000205"]
          },
          %{
            "task" => "Target reply without persisted root_thread_ts",
            "source_refs" => ["slack://T1/C1/channel/1700000001.000105"]
          },
          %{
            "task" => "Target reply truncated out of 3-message display summary",
            "source_refs" => ["slack://T1/C1/channel/1700000001.000109"]
          }
        ]
      }
    }

    assert {:ok,
            [
              %{
                "index" => 0,
                "status" => "suppressed_stale",
                "reason" => "unanchored_delegation"
              },
              %{
                "index" => 1,
                "status" => "routed",
                "source_count" => 1
              },
              %{
                "index" => 2,
                "status" => "routed",
                "source_count" => 1
              }
            ]} =
             DelegationEffect.apply(claim,
               freshness_port: __MODULE__.FreshWithRoots,
               delegation_port: __MODULE__.DelegationPort,
               port_opts: [
                 test_pid: SystemsRuntime.Proc.self(),
                 message_roots: %{
                   "1700000001.000105" => "1700000001.000100",
                   "1700000001.000109" => "1700000001.000100",
                   "1700000002.000205" => "1700000002.000200"
                 }
               ]
             )

    assert_received {:delegation_prepare, ^claim,
                     %{"task" => "Target reply without persisted root_thread_ts"},
                     "triage-delegation:obligation-legacy-channel:1"}

    assert_received {:delegation_commit, "triage-delegation:obligation-legacy-channel:1"}

    assert_received {:delegation_prepare, ^claim,
                     %{"task" => "Target reply truncated out of 3-message display summary"},
                     "triage-delegation:obligation-legacy-channel:2"}

    assert_received {:delegation_commit, "triage-delegation:obligation-legacy-channel:2"}
  end

  defmodule RouterAdmissionPort do
    def prepare(_claim, _delegation, request_id), do: {:ok, request_id}
    def commit(request_id), do: {:ok, %{"disposition" => "routed", "request_id" => request_id}}
  end

  defmodule Fresh do
    def check(claim, opts) do
      SystemsRuntime.Proc.send(Keyword.fetch!(opts, :test_pid), {:freshness_check, claim})
      {:ok, %{status: :fresh, authority_ref: :same}}
    end
  end

  defmodule FreshWithRoots do
    def check(claim, opts) do
      SystemsRuntime.Proc.send(Keyword.fetch!(opts, :test_pid), {:freshness_check, claim})

      {:ok,
       %{
         status: :fresh,
         authority_ref: :same,
         message_roots: Keyword.fetch!(opts, :message_roots)
       }}
    end
  end

  defmodule ChangingFreshness do
    def check(claim, opts) do
      pid = Keyword.fetch!(opts, :test_pid)
      SystemsRuntime.Proc.send(pid, {:freshness_check, claim})
      count = Process.get({__MODULE__, :count}, 0) + 1
      Process.put({__MODULE__, :count}, count)
      {:ok, %{status: :fresh, authority_ref: count}}
    end
  end

  defmodule DelegationPort do
    def prepare(claim, delegation, request_id) do
      pid = Process.get(:delegation_test_pid)
      SystemsRuntime.Proc.send(pid, {:delegation_prepare, claim, delegation, request_id})
      {:ok, %{request_id: request_id, test_pid: pid}}
    end

    def commit(%{request_id: request_id, test_pid: pid}) do
      SystemsRuntime.Proc.send(pid, {:delegation_commit, request_id})
      {:ok, %{"disposition" => "routed", "request_id" => request_id}}
    end
  end

  defmodule RetryableDelegationPort do
    def prepare(_claim, _delegation, request_id),
      do: {:ok, %{request_id: request_id}}

    def commit(_prepared), do: {:error, :task_create_unavailable, true}
  end

  setup do
    Process.put(:delegation_test_pid, SystemsRuntime.Proc.self())
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
