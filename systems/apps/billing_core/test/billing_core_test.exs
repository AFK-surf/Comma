defmodule BillingCoreTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias BillingCore.{Charges, FeeControl, LLMMetering, ResourceMetering, State}
  alias BillingCore.Metering.PricingBackfill

  unless Code.ensure_loaded?(BillingCore.Repo.Migrations.SeedJevPricing) do
    Code.require_file("../priv/repo/migrations/20260920000002_seed_jev_pricing.exs", __DIR__)
  end

  defmodule TypedSinkFake do
    def enqueue(rows, _opts), do: insert(rows) |> then(fn _ -> :ok end)

    def insert(rows) do
      send(Application.fetch_env!(:billing_core, :contract_test_pid), {:typed_rows, rows})
      {:ok, length(rows)}
    end
  end

  defmodule RaisingSink do
    def insert(_rows), do: raise("charge sink down")
  end

  defmodule FakeRepo do
    def transaction(fun) do
      send(Application.fetch_env!(:billing_core, :contract_test_pid), :repo_transaction)

      try do
        {:ok, fun.()}
      catch
        {:rollback, reason} -> {:error, reason}
      end
    end

    def rollback(reason) do
      send(Application.fetch_env!(:billing_core, :contract_test_pid), {:repo_rollback, reason})
      throw({:rollback, reason})
    end
  end

  defmodule SQLAccountFixture do
    def query(query, params) do
      cond do
        query =~ "INSERT INTO billing_accounts" ->
          %{rows: [[List.first(params)]], num_rows: 1}

        query =~ "SELECT surface" and query =~ "FROM billing_accounts" ->
          %{rows: [], num_rows: 0}

        query =~ "FROM billing_accounts" ->
          %{rows: [["active"]], num_rows: 1}

        true ->
          nil
      end
    end
  end

  defmodule FakeSQL do
    def query!(_repo, query, params, _opts \\ []) do
      send(Application.fetch_env!(:billing_core, :contract_test_pid), {:sql_query, query, params})

      SQLAccountFixture.query(query, params) ||
        cond do
          query =~ "FROM credit_ledger" and query =~ "SELECT" ->
            %{rows: [], num_rows: 0}

          query =~ "FROM pending_meter_charges" and query =~ "SELECT" ->
            %{rows: [], num_rows: 0}

          query =~ "FROM meter_pricing_catalog" ->
            %{rows: [["v1", 2, "token"]], num_rows: 1}

          query =~ "jsonb_agg(policy_snapshot)" ->
            %{rows: [[1_000, []]], num_rows: 1}

          query =~ "FROM credit_balances" ->
            %{rows: [[1_000]], num_rows: 1}

          query =~ "FROM credit_grants" ->
            %{rows: [["grant_1", 1_000]], num_rows: 1}

          query =~ "FROM meter_rounding_remainders" ->
            %{rows: [[0]], num_rows: 1}

          true ->
            %{rows: [], num_rows: 0}
        end
    end
  end

  defmodule UnlimitedSQL do
    def query!(_repo, query, params, _opts \\ []) do
      send(Application.fetch_env!(:billing_core, :contract_test_pid), {:sql_query, query, params})

      SQLAccountFixture.query(query, params) ||
        cond do
          query =~ "FROM credit_ledger" and query =~ "SELECT" ->
            %{rows: [], num_rows: 0}

          query =~ "FROM meter_pricing_catalog" ->
            %{rows: [["v1", 2, "token"]], num_rows: 1}

          query =~ "jsonb_agg(policy_snapshot)" ->
            %{
              rows: [
                [
                  0,
                  [
                    %{
                      "usage_credits" => %{"mode" => "unlimited_metered"},
                      "llm_models" => %{"mode" => "unrestricted", "models" => []},
                      "vm_concurrency" => %{"mode" => "unrestricted", "limit" => nil},
                      "storage_hard_cap" => %{"mode" => "unrestricted", "bytes" => nil}
                    }
                  ]
                ]
              ],
              num_rows: 1
            }

          true ->
            %{rows: [], num_rows: 0}
        end
    end
  end

  defmodule RepoRaisingSink do
    def insert(_rows), do: {:error, :sink_down}
  end

  defmodule TimeoutObservabilitySink do
    def enqueue(_rows, _opts), do: exit(:timeout)
  end

  defmodule MissingPricingSQL do
    def query!(_repo, query, params, _opts \\ []) do
      send(Application.fetch_env!(:billing_core, :contract_test_pid), {:sql_query, query, params})

      SQLAccountFixture.query(query, params) ||
        cond do
          query =~ "FROM pending_meter_charges" and query =~ "SELECT" ->
            %{
              rows: [
                [
                  "pending_1",
                  "ba_pending",
                  "src_pending",
                  "llm",
                  "openai",
                  "missing",
                  Jason.encode!(%{
                    "meter_components" => [
                      %{"component" => "input", "meter_unit" => "token", "quantity" => 10}
                    ]
                  }),
                  ~U[2026-06-17 10:00:00Z],
                  0,
                  nil
                ]
              ],
              num_rows: 1
            }

          query =~ "FROM meter_pricing_catalog" ->
            %{rows: [], num_rows: 0}

          query =~ "FROM credit_ledger" and query =~ "SELECT" ->
            %{rows: [], num_rows: 0}

          true ->
            %{rows: [], num_rows: 0}
        end
    end
  end

  defmodule MapSnapshotPendingSQL do
    def query!(_repo, query, params, _opts \\ []) do
      send(Application.fetch_env!(:billing_core, :contract_test_pid), {:sql_query, query, params})

      SQLAccountFixture.query(query, params) ||
        cond do
          query =~ "FROM pending_meter_charges" and query =~ "SELECT" ->
            %{
              rows: [
                [
                  "pending_1",
                  "ba_pending",
                  "src_pending",
                  "llm",
                  "openai",
                  "gpt-x",
                  %{
                    "meter_components" => [
                      %{"component" => "input", "meter_unit" => "token", "quantity" => 10}
                    ]
                  },
                  ~U[2026-06-17 10:00:00Z],
                  0,
                  nil
                ]
              ],
              num_rows: 1
            }

          query =~ "FROM meter_pricing_catalog" ->
            %{rows: [["v1", 2, "token"]], num_rows: 1}

          query =~ "FROM credit_ledger" and query =~ "SELECT" ->
            %{rows: [], num_rows: 0}

          query =~ "jsonb_agg(policy_snapshot)" ->
            %{rows: [[1_000, []]], num_rows: 1}

          query =~ "FROM credit_balances" ->
            %{rows: [[1_000]], num_rows: 1}

          query =~ "FROM credit_grants" ->
            %{rows: [], num_rows: 0}

          query =~ "FROM meter_rounding_remainders" ->
            %{rows: [[0]], num_rows: 1}

          true ->
            %{rows: [], num_rows: 0}
        end
    end
  end

  defmodule PagedGrantSQL do
    def query!(_repo, query, params, _opts \\ []) do
      send(Application.fetch_env!(:billing_core, :contract_test_pid), {:sql_query, query, params})

      SQLAccountFixture.query(query, params) ||
        cond do
          query =~ "FROM credit_ledger" and query =~ "SELECT" ->
            %{rows: [], num_rows: 0}

          query =~ "FROM meter_pricing_catalog" ->
            %{rows: [["v1", 1, "token"]], num_rows: 1}

          query =~ "jsonb_agg(policy_snapshot)" ->
            %{rows: [[513, []]], num_rows: 1}

          query =~ "FROM credit_grants" and query =~ "COALESCE(expires_at" ->
            %{rows: [["grant_513", 1, nil, 0]], num_rows: 1}

          query =~ "FROM credit_grants" ->
            rows = for index <- 1..512, do: ["grant_#{index}", 1, nil, 0]
            %{rows: rows, num_rows: 512}

          query =~ "FROM meter_rounding_remainders" ->
            %{rows: [[0]], num_rows: 1}

          true ->
            %{rows: [], num_rows: 0}
        end
    end
  end

  setup do
    previous = Application.get_env(:billing_core, :contract_test_pid)
    Application.put_env(:billing_core, :contract_test_pid, self())

    on_exit(fn ->
      if previous do
        Application.put_env(:billing_core, :contract_test_pid, previous)
      else
        Application.delete_env(:billing_core, :contract_test_pid)
      end
    end)
  end

  @now ~U[2026-06-17 10:00:00Z]

  test "charges LLM cache/input/output components with fixed credits per USD" do
    state =
      State.new(
        pricing_catalog: [
          price(:llm, :input, "openai", "gpt-x", 2),
          price(:llm, :output, "openai", "gpt-x", 8),
          price(:llm, :cache_read, "openai", "gpt-x", 1),
          price(:llm, :cache_write, "openai", "gpt-x", 4)
        ],
        grants: [grant("ba_1", 10_000)]
      )

    event =
      meter_event(%{
        state: state,
        resource_kind: :llm,
        meter_components: [
          %{component: :input, meter_unit: :token, quantity: 100},
          %{component: :output, meter_unit: :token, quantity: 50},
          %{component: :cache_read, meter_unit: :token, quantity: 25},
          %{component: :cache_write, meter_unit: :token, quantity: 10}
        ]
      })

    assert {:ok, charge, next_state} = Charges.charge_meter_event(event)
    assert charge.credits_per_usd == 1_000_000
    assert charge.charged_credits == 665
    assert remaining(next_state.grants, "ba_1") == 9_335

    assert Enum.map(charge.pricing_components, & &1.component) == [
             :input,
             :output,
             :cache_read,
             :cache_write
           ]
  end

  test "tenant subscription calls retain usage without credit admission or ledger charges" do
    fact = %{
      tenant_account_pool: true,
      billing_account_id: "empty-account",
      source_key: "subscription-call",
      model: "gpt-5",
      typed_sink: TypedSinkFake,
      sql_runner: fn _, _ -> flunk("subscription call must not query the credit ledger") end,
      usage: %{"prompt_tokens" => 100, "completion_tokens" => 50}
    }

    assert :ok = LLMMetering.before_llm_call(fact)
    assert :ok = deliver_llm(fact)

    assert_receive {:typed_rows,
                    [
                      %{
                        "billing_account_id" => "empty-account",
                        "model" => "gpt-5",
                        "charge_status" => "not_billable"
                      }
                    ]}
  end

  test "LLM metering subtracts cached tokens from ordinary input and infers provider" do
    state =
      State.new(
        pricing_catalog: [
          price(:llm, :input, "openai", "gpt-x", 2),
          price(:llm, :output, "openai", "gpt-x", 8),
          price(:llm, :cache_read, "openai", "gpt-x", 1),
          price(:llm, :cache_write, "openai", "gpt-x", 4)
        ],
        grants: [grant("ba_1", 10_000)]
      )

    assert {:ok, charge, state} =
             deliver_llm(%{
               state: state,
               typed_sink: TypedSinkFake,
               billing_account_id: "ba_1",
               source_key: "llm_cache_split",
               model: "GPT-X",
               metered_at: @now,
               usage: %{
                 "prompt_tokens" => 100,
                 "completion_tokens" => 50,
                 "cache_read_input_tokens" => 25,
                 "cache_write_input_tokens" => 10
               }
             })

    assert charge.charged_credits == 595
    assert remaining(state.grants, "ba_1") == 9_405

    assert Enum.map(charge.pricing_components, &{&1.component, &1.quantity}) == [
             {:input, 65},
             {:output, 50},
             {:cache_read, 25},
             {:cache_write, 10}
           ]

    assert_receive {:typed_rows, [%{"provider" => "openai", "sku" => "gpt-x"}]}
  end

  test "Jev usage charges input tokens at the seeded price and keeps output free" do
    state =
      State.new(
        pricing_catalog: BillingCore.Repo.Migrations.SeedJevPricing.prices(),
        grants: [Map.put(grant("ba_1", 100_000), :expires_at, ~U[2026-10-01 00:00:00Z])]
      )

    assert {:ok, charge, state} =
             deliver_llm(%{
               state: state,
               typed_sink: TypedSinkFake,
               billing_account_id: "ba_1",
               source_key: "jev-input-charge",
               provider: "typesafe",
               model: "jev-1.13.0",
               metered_at: ~U[2026-09-20 01:00:00Z],
               usage: %{"prompt_tokens" => 1_000_000, "completion_tokens" => 100_000}
             })

    assert charge.charged_credits == 42_000
    assert remaining(state.grants, "ba_1") == 58_000
    assert_receive {:typed_rows, [%{"provider" => "typesafe", "sku" => "jev-1.13.0"}]}
  end

  for {alias_model, source_key} <- [
        {"5.6-sol", "legacy_56_sol"},
        {"gpt-5.6", "official_56_alias"}
      ] do
    test "LLM metering canonicalizes #{alias_model} to the Sol pricing SKU" do
      state =
        State.new(
          pricing_catalog: [
            price(:llm, :input, "openai", "gpt-5.6-sol", 5),
            price(:llm, :output, "openai", "gpt-5.6-sol", 30)
          ],
          grants: [grant("ba_1", 10_000)]
        )

      assert {:ok, charge, _state} =
               deliver_llm(%{
                 state: state,
                 typed_sink: TypedSinkFake,
                 billing_account_id: "ba_1",
                 source_key: unquote(source_key),
                 model: unquote(alias_model),
                 metered_at: @now,
                 usage: %{"prompt_tokens" => 10, "completion_tokens" => 5}
               })

      assert charge.provider == "openai"
      assert charge.sku == "gpt-5.6-sol"

      assert_receive {:typed_rows, [%{"provider" => "openai", "sku" => "gpt-5.6-sol"}]}
    end
  end

  test "idempotency reuses billing account and source key charge" do
    state =
      State.new(
        pricing_catalog: [price(:vm, :runtime, "fly", "shared", 10)],
        grants: [grant("ba_1", 100)]
      )

    event =
      meter_event(%{
        state: state,
        resource_kind: :vm,
        provider: "fly",
        sku: "shared",
        quantity: 2
      })

    assert {:ok, charge, next_state} = Charges.charge_meter_event(event)
    assert {:ok, retry, retry_state} = Charges.charge_meter_event(%{event | state: next_state})

    assert charge.charged_credits == 20
    assert retry.idempotent == true
    assert remaining(retry_state.grants, "ba_1") == 80
    assert length(retry_state.credit_ledger) == 1
  end

  test "charge path writes billing charge event when typed sink is configured" do
    state =
      State.new(
        pricing_catalog: [price(:llm, :input, "openai", "gpt-x", 2)],
        grants: [grant("ba_1", 100)]
      )

    event =
      meter_event(%{
        state: state,
        resource_kind: :llm,
        typed_sink: TypedSinkFake,
        owner_snapshot: owner(),
        entrypoint: "conversation_send",
        actor_type: "user",
        meter_components: [%{component: :input, meter_unit: :token, quantity: 10}]
      })

    assert {:ok, charge, _state} = Charges.charge_meter_event(event)
    assert charge.charged_credits == 20

    assert_receive {:typed_rows,
                    [
                      %{
                        "resource_kind" => "charge",
                        "billing_account_id" => "ba_1",
                        "source_key" => "src_1",
                        "charged_credits" => 20,
                        "entrypoint" => "conversation_send"
                      }
                    ]}
  end

  test "charge path reports typed charge event sink failures without crashing" do
    state =
      State.new(
        pricing_catalog: [price(:vm, :runtime, "fly", "shared", 10)],
        grants: [grant("ba_1", 100)]
      )

    event =
      meter_event(%{
        state: state,
        resource_kind: :vm,
        provider: "fly",
        sku: "shared",
        quantity: 1,
        typed_sink: RaisingSink,
        owner_snapshot: owner()
      })

    assert {:error, {:charge_event_sink, {RuntimeError, "charge sink down"}}} =
             Charges.charge_meter_event(event)
  end

  test "LLM metering adapter writes typed row before charging" do
    state =
      State.new(
        pricing_catalog: [
          price(:llm, :input, "openai", "gpt-x", 2),
          price(:llm, :output, "openai", "gpt-x", 8)
        ],
        grants: [grant("ba_1", 1_000)]
      )

    assert {:ok, charge, _state} =
             deliver_llm(%{
               state: state,
               typed_sink: TypedSinkFake,
               provider: "openai",
               model: "gpt-x",
               billing_account_id: "ba_1",
               surface: "comma",
               product_owner_type: "workspace",
               product_owner_id: "ws_1",
               tenant_id: "tenant_1",
               group_id: "group_1",
               actor_type: "user",
               entrypoint: "conversation_send",
               source_key: "llm:req_1",
               metered_at: @now,
               usage: %{"prompt_tokens" => 10, "completion_tokens" => 5}
             })

    assert charge.charged_credits == 60

    assert_receive {:typed_rows,
                    [
                      %{
                        "resource_kind" => "llm",
                        "billing_account_id" => "ba_1",
                        "source_key" => "llm:req_1",
                        "entrypoint" => "conversation_send"
                      }
                    ]}
  end

  test "LLM metering adapter records unattributed rows without charging" do
    assert :ok =
             deliver_llm(%{
               typed_sink: TypedSinkFake,
               provider: "openai",
               model: "gpt-x",
               tenant_id: "tenant_1",
               group_id: "group_1",
               actor_type: "external_user",
               entrypoint: "site_llm",
               source_key: "llm:req_unowned",
               usage: %{"prompt_tokens" => 1}
             })

    assert_receive {:typed_rows,
                    [
                      %{
                        "billing_account_id" => "unattributed",
                        "charge_status" => "unattributed",
                        "quality" => quality
                      }
                    ]}

    assert Jason.decode!(quality) == ["billing_owner_missing"]
  end

  test "LLM metering adapter projects v1.2 telemetry fields to typed rows" do
    started_at_ms = 1_725_000_000_123

    expected_started_at =
      started_at_ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()

    assert :ok =
             deliver_llm(%{
               typed_sink: TypedSinkFake,
               provider: "openai",
               model: "gpt-x",
               tenant_id: "tenant_1",
               group_id: "group_1",
               actor_type: "system",
               entrypoint: "agent_round",
               source_key: "llm:req_v12",
               duration_ms: 321,
               started_at_ms: started_at_ms,
               first_token_ms: 45,
               attempts: 3,
               response_kind: :error,
               app_revision: "2026.07.08",
               llm_error: %{"category" => "retryable_provider_error", "status" => 429}
             })

    assert_receive {:typed_rows,
                    [
                      %{
                        "duration_ms" => 321,
                        "started_at" => ^expected_started_at,
                        "first_token_ms" => 45,
                        "attempts" => 3,
                        "response_kind" => "error",
                        "app_revision" => "2026.07.08",
                        "error_type" => "retryable_provider_error",
                        "http_status" => 429
                      }
                    ]}
  end

  test "agent observability logs timeout discards" do
    previous_sink = Application.get_env(:billing_core, :agent_observability_typed_sink)
    Application.put_env(:billing_core, :agent_observability_typed_sink, TimeoutObservabilitySink)

    try do
      log =
        capture_log(fn ->
          assert {:error, {:exit, :timeout}} =
                   BillingCore.AgentObservability.agent_run(agent_observation_run_fact())
        end)

      assert log =~ "agent observability"
      assert log =~ "timeout"
      assert log =~ "discard"
    after
      restore_billing_env(:agent_observability_typed_sink, previous_sink)
    end
  end

  test "repo charge engine runs in a transaction and locks only bounded account rows" do
    assert {:ok, charge} =
             BillingCore.RepoCharges.charge_meter_event(%{
               repo: FakeRepo,
               sql_runner: FakeSQL,
               billing_account_id: "ba_repo",
               source_key: "src_repo",
               resource_kind: "llm",
               provider: "openai",
               sku: "gpt-x",
               metered_at: @now,
               meter_components: [%{component: :input, meter_unit: :token, quantity: 20}]
             })

    assert charge.charged_credits == 40
    assert charge.balance_after == 960
    assert_received :repo_transaction

    queries = flush_sql_queries()

    assert {_account_insert, ["ba_repo", "unknown", "unknown", "unknown"]} =
             find_query(queries, "INSERT INTO billing_accounts")

    assert {_balance_insert, ["ba_repo"]} = find_query(queries, "INSERT INTO credit_balances")

    assert {_advisory_lock, ["ba_repo", "src_repo"]} =
             find_query(queries, "pg_advisory_xact_lock")

    assert {ledger_lookup, ["ba_repo", "src_repo"]} =
             find_query(queries, "FROM credit_ledger", "SELECT")

    assert ledger_lookup =~ "FROM credit_ledger"

    assert {account_lock, ["ba_repo"]} =
             find_query(queries, "FROM billing_accounts", "FOR UPDATE")

    assert account_lock =~ "FROM billing_accounts"

    assert {grant_lock, ["ba_repo", @now]} =
             find_query(queries, "FROM credit_grants", "FOR UPDATE")

    assert grant_lock =~ "FROM credit_grants"
    assert grant_lock =~ "LIMIT 512"
    assert grant_lock =~ "FOR UPDATE"

    assert {remainder_lock, ["ba_repo", "llm", "openai", "gpt-x"]} =
             find_query(queries, "FROM meter_rounding_remainders")

    assert remainder_lock =~ "FROM meter_rounding_remainders"
    assert remainder_lock =~ "FOR UPDATE"

    assert {ledger_insert, _params} = find_query(queries, "INSERT INTO credit_ledger")
    assert ledger_insert =~ "INSERT INTO credit_ledger"
    assert ledger_insert =~ "ON CONFLICT (billing_account_id, source_key) DO NOTHING"
  end

  test "repo charge records unlimited metered ledger without consuming grants or grace" do
    assert {:ok, charge} =
             BillingCore.RepoCharges.charge_meter_event(%{
               repo: FakeRepo,
               sql_runner: UnlimitedSQL,
               typed_sink: TypedSinkFake,
               billing_account_id: "ba_unlimited",
               surface: "bridge",
               product_owner_type: "organization",
               product_owner_id: "org_unlimited",
               tenant_id: "tenant_unlimited",
               group_id: "group_unlimited",
               actor_type: "external_user",
               entrypoint: "direct_deliver",
               source_key: "src_unlimited",
               resource_kind: "llm",
               provider: "openai",
               sku: "gpt-x",
               metered_at: @now,
               meter_components: [%{component: :input, meter_unit: :token, quantity: 20}]
             })

    assert charge.status == "unlimited_metered"
    assert charge.entitlement_mode == :unlimited_metered
    assert charge.calculated_credits == 40
    assert charge.charged_credits == 0
    assert charge.grace_credits == 0
    assert charge.grant_debits == []
    assert charge.balance_after == 0

    assert_receive {:typed_rows,
                    [
                      %{
                        "resource_kind" => "charge",
                        "status" => "unlimited_metered",
                        "entitlement_mode" => "unlimited_metered",
                        "charged_credits" => 0,
                        "grace_credits" => 0
                      }
                    ]}

    queries = flush_sql_queries()

    refute Enum.any?(queries, fn {query, _params} ->
             query =~ "FROM credit_grants" and query =~ "FOR UPDATE"
           end)

    refute find_query(queries, "UPDATE credit_grants")

    assert {ledger_insert, _params} = find_query(queries, "INSERT INTO credit_ledger")
    assert ledger_insert =~ "'unlimited_metered'"
  end

  test "repo charge engine emits billing charge events" do
    assert {:ok, charge} =
             BillingCore.RepoCharges.charge_meter_event(%{
               repo: FakeRepo,
               sql_runner: FakeSQL,
               typed_sink: TypedSinkFake,
               billing_account_id: "ba_repo_charge",
               surface: "comma",
               product_owner_type: "workspace",
               product_owner_id: "ws_charge",
               tenant_id: "tenant_charge",
               group_id: "group_charge",
               actor_type: "user",
               entrypoint: "conversation_send",
               source_key: "src_repo_charge",
               resource_kind: "llm",
               provider: "openai",
               sku: "gpt-x",
               metered_at: @now,
               meter_components: [%{component: :input, meter_unit: :token, quantity: 20}]
             })

    assert charge.charged_credits == 40

    assert_receive {:typed_rows,
                    [
                      %{
                        "resource_kind" => "charge",
                        "billing_account_id" => "ba_repo_charge",
                        "source_key" => "src_repo_charge",
                        "charged_credits" => 40
                      }
                    ]}
  end

  test "repo charge keeps PG transaction when billing charge event sink fails" do
    assert {:ok, charge} =
             BillingCore.RepoCharges.charge_meter_event(%{
               repo: FakeRepo,
               sql_runner: FakeSQL,
               typed_sink: RepoRaisingSink,
               billing_account_id: "ba_repo_rollback",
               surface: "comma",
               product_owner_type: "workspace",
               product_owner_id: "ws_rollback",
               tenant_id: "tenant_rollback",
               group_id: "group_rollback",
               actor_type: "user",
               entrypoint: "conversation_send",
               source_key: "src_repo_rollback",
               resource_kind: "llm",
               provider: "openai",
               sku: "gpt-x",
               metered_at: @now,
               meter_components: [%{component: :input, meter_unit: :token, quantity: 20}]
             })

    assert charge.status == "charged"

    refute_received {:repo_rollback, {:charge_event_sink, :sink_down}}
  end

  test "repo charge pages active grants until the charge is fully covered" do
    assert {:ok, charge} =
             BillingCore.RepoCharges.charge_meter_event(%{
               repo: FakeRepo,
               sql_runner: PagedGrantSQL,
               billing_account_id: "ba_paged",
               source_key: "src_paged",
               resource_kind: "llm",
               provider: "openai",
               sku: "gpt-x",
               metered_at: @now,
               meter_components: [%{component: :input, meter_unit: :token, quantity: 513}]
             })

    assert charge.charged_credits == 513
    assert charge.grace_credits == 0
    assert length(charge.grant_debits) == 513

    queries = flush_sql_queries()

    assert Enum.count(queries, fn {query, _params} ->
             query =~ "FROM credit_grants" and query =~ "FOR UPDATE"
           end) == 2
  end

  test "LLM metering adapter uses repo charge path when no in-memory state is supplied" do
    assert {:ok, charge} =
             deliver_llm(%{
               repo: FakeRepo,
               sql_runner: FakeSQL,
               typed_sink: TypedSinkFake,
               provider: "openai",
               model: "gpt-x",
               billing_account_id: "ba_repo",
               surface: "comma",
               product_owner_type: "workspace",
               product_owner_id: "ws_repo",
               tenant_id: "tenant_repo",
               group_id: "group_repo",
               actor_type: "user",
               entrypoint: "conversation_send",
               source_key: "llm:req_repo",
               metered_at: @now,
               usage: %{"prompt_tokens" => 20}
             })

    assert charge.charged_credits == 40
    assert_received {:typed_rows, [%{"resource_kind" => "llm", "source_key" => "llm:req_repo"}]}
    assert_received :repo_transaction
  end

  test "LLM metering adapter reads nested billing context from Salix runtime facts" do
    assert {:ok, charge} =
             deliver_llm(%{
               repo: FakeRepo,
               sql_runner: FakeSQL,
               typed_sink: TypedSinkFake,
               provider: "openai",
               model: "gpt-x",
               source_key: "llm:nested_context",
               metered_at: @now,
               billing_context: %{
                 "billing_account_id" => "ba_nested",
                 "surface" => "bridge",
                 "product_owner_type" => "organization",
                 "product_owner_id" => "org_nested",
                 "salix_tenant_id" => "tenant_nested",
                 "salix_group_id" => "group_nested",
                 "actor_type" => "external_user",
                 "entrypoint" => "im_router"
               },
               usage: %{"prompt_tokens" => 20}
             })

    assert charge.charged_credits == 40

    assert_receive {:typed_rows,
                    [
                      %{
                        "resource_kind" => "llm",
                        "billing_account_id" => "ba_nested",
                        "surface" => "bridge",
                        "group_id" => "group_nested",
                        "entrypoint" => "im_router",
                        "actor_type" => "external_user"
                      }
                    ]}
  end

  test "resource metering uses repo charge path when no in-memory state is supplied" do
    assert {:ok, charge} =
             ResourceMetering.meter_vm_interval(%{
               repo: FakeRepo,
               sql_runner: FakeSQL,
               typed_sink: TypedSinkFake,
               source_key: "vm:req_repo",
               provider: "sprites",
               sku: "cloud-vm",
               quantity: 20,
               duration_seconds: 20,
               metered_at: @now,
               owner_snapshot: owner()
             })

    assert charge.charged_credits == 40
    assert_received {:typed_rows, [%{"resource_kind" => "vm", "source_key" => "vm:req_repo"}]}
    assert_received :repo_transaction
  end

  test "repo resource metering preserves explicit quantity without duration fields" do
    assert {:ok, charge} =
             ResourceMetering.meter_vm_interval(%{
               repo: FakeRepo,
               sql_runner: FakeSQL,
               typed_sink: TypedSinkFake,
               source_key: "vm:req_quantity_only",
               provider: "sprites",
               sku: "cloud-vm",
               quantity: 20,
               metered_at: @now,
               owner_snapshot: owner()
             })

    assert charge.charged_credits == 40

    assert_receive {:typed_rows,
                    [
                      %{
                        "resource_kind" => "vm",
                        "source_key" => "vm:req_quantity_only",
                        "duration_seconds" => 20
                      }
                    ]}
  end

  test "fee-control miss performs bounded repo balance probe when repo is supplied" do
    state = State.new()

    assert {:ok, result, _state} =
             FeeControl.check(state, %{
               repo: FakeRepo,
               sql_runner: FakeSQL,
               billing_account_id: "ba_probe",
               provider: "openai",
               sku: "gpt-x",
               estimated_credits: 10
             })

    assert result.query_performed == true
    assert result.balance_snapshot == 1_000

    queries = flush_sql_queries()

    assert {balance_query, ["ba_probe", _checked_at]} =
             find_query(queries, "jsonb_agg(policy_snapshot)")

    assert balance_query =~ "FROM credit_grants"
  end

  test "fee-control force refresh probes bounded balance even on cache hit" do
    state =
      State.new(
        fee_control_cache: %{
          {"ba_probe", "openai", "gpt-x"} => %{
            snapshot: %{balance_snapshot: 2_000},
            cached_at_ms: 1_000
          }
        }
      )

    assert {:ok, result, _state} =
             FeeControl.check(state, %{
               repo: FakeRepo,
               sql_runner: FakeSQL,
               billing_account_id: "ba_probe",
               provider: "openai",
               sku: "gpt-x",
               estimated_credits: 10,
               now: 1_010,
               force_refresh: true
             })

    assert result.cache_hit == true
    assert result.query_performed == true
    assert result.cache_age_ms == 10
    assert result.balance_snapshot == 1_000
  end

  test "repo pricing backfill scans pending rows with bounded lock" do
    assert %{charged_count: 0, pending_count: 0} =
             PricingBackfill.run(%{
               repo: FakeRepo,
               sql_runner: FakeSQL,
               now: @now,
               limit: 25
             })

    assert_received :repo_transaction
    queries = flush_sql_queries()

    assert {expire_query, [@now, 25]} = find_query(queries, "UPDATE pending_meter_charges")
    assert expire_query =~ "expired_unpriced"
    assert expire_query =~ "LIMIT $2"
    assert expire_query =~ "FOR UPDATE SKIP LOCKED"

    assert {pending_query, [@now, 25]} = find_query(queries, "FROM pending_meter_charges")
    assert pending_query =~ "LIMIT $2"
    assert pending_query =~ "FOR UPDATE SKIP LOCKED"
  end

  test "repo pricing backfill keeps still-unpriced pending rows" do
    assert %{charged_count: 0, pending_count: 1} =
             PricingBackfill.run(%{
               repo: FakeRepo,
               sql_runner: MissingPricingSQL,
               now: @now,
               limit: 25
             })

    queries = flush_sql_queries()
    refute find_query(queries, "DELETE FROM pending_meter_charges")
  end

  test "repo pricing backfill accepts jsonb map snapshots" do
    previous_sink = Application.get_env(:billing_core, :charge_typed_sink, :unset)
    Application.put_env(:billing_core, :charge_typed_sink, RaisingSink)

    on_exit(fn ->
      case previous_sink do
        :unset -> Application.delete_env(:billing_core, :charge_typed_sink)
        sink -> Application.put_env(:billing_core, :charge_typed_sink, sink)
      end
    end)

    assert %{charged_count: 1, pending_count: 0} =
             PricingBackfill.run(%{
               repo: FakeRepo,
               sql_runner: MapSnapshotPendingSQL,
               now: @now,
               limit: 25
             })

    assert_receive :repo_transaction
    assert_receive :repo_transaction
    refute_receive :repo_transaction, 0

    queries = flush_sql_queries()
    assert find_query(queries, "DELETE FROM pending_meter_charges")
  end

  test "consumes grants before balance and records grace without negative balance" do
    state =
      State.new(
        pricing_catalog: [price(:storage, :byte_second, "aws", "standard", 1)],
        grants: [grant("ba_1", 30)]
      )

    event =
      meter_event(%{
        state: state,
        resource_kind: :storage,
        provider: "aws",
        sku: "standard",
        quantity: 75
      })

    assert {:ok, charge, next_state} = Charges.charge_meter_event(event)
    assert charge.grant_credits == 30
    assert charge.grace_credits == 45
    assert charge.status == :grace
    assert remaining(next_state.grants, "ba_1") == 0
  end

  test "fractional low-value samples accumulate in rounding remainders" do
    state =
      State.new(
        pricing_catalog: [
          %{
            resource_kind: :storage,
            component: :byte_second,
            provider: "aws",
            sku: "standard",
            usd_micros_per_unit: 0.25,
            effective_at: @now
          }
        ],
        grants: [grant("ba_1", 10)]
      )

    event =
      meter_event(%{
        state: state,
        resource_kind: :storage,
        provider: "aws",
        sku: "standard",
        quantity: 1
      })

    assert {:ok, first, state} = Charges.charge_meter_event(event)
    assert first.charged_credits == 0

    assert {:ok, second, state} =
             Charges.charge_meter_event(%{event | state: state, source_key: "src_2"})

    assert second.charged_credits == 0

    assert {:ok, third, state} =
             Charges.charge_meter_event(%{event | state: state, source_key: "src_3"})

    assert third.charged_credits == 0

    assert {:ok, fourth, state} =
             Charges.charge_meter_event(%{event | state: state, source_key: "src_4"})

    assert fourth.charged_credits == 1
    assert remaining(state.grants, "ba_1") == 9
  end

  test "missing pricing enters pending and backfill charges only active pending rows" do
    state = State.new(grants: [grant("ba_1", 100)])

    event =
      meter_event(%{
        state: state,
        resource_kind: :vm,
        provider: "fly",
        sku: "missing",
        quantity: 3
      })

    assert {:pending, pending, state} = Charges.charge_meter_event(event)
    assert pending.pricing_status == :missing_pricing

    state = %{
      state
      | pricing_catalog: [price(:vm, :runtime, "fly", "missing", 7)]
    }

    assert {:ok, summary, state} =
             PricingBackfill.run(%{state: state, now: DateTime.add(@now, 60, :second)})

    assert summary.charged_count == 1
    assert summary.expired_count == 0
    assert remaining(state.grants, "ba_1") == 79
    assert map_size(state.pending_meter_charges) == 0
  end

  test "shadow fee-control cache hit avoids bounded query and never blocks" do
    state = State.new()

    query_fun = fn ->
      send(self(), :fee_control_query)
      %{balance_snapshot: 5}
    end

    attrs = %{
      billing_account_id: "ba_1",
      provider: "openai",
      sku: "gpt-x",
      estimated_credits: 10,
      query_fun: query_fun,
      now: 1000
    }

    assert {:ok, first, state} = FeeControl.check(state, attrs)
    assert first.allowed? == true
    assert first.would_block == true
    assert first.query_performed == true
    assert_received :fee_control_query

    assert {:ok, second, _state} = FeeControl.check(state, %{attrs | now: 1010})
    assert second.allowed? == true
    assert second.cache_hit == true
    assert second.query_performed == false
    refute_received :fee_control_query
  end

  test "fee-control server keeps TTL cache and writes typed checks" do
    name = :"fee_control_#{System.unique_integer([:positive])}"
    start_supervised!({BillingCore.FeeControl.Server, name: name}, id: name)

    test_pid = self()

    query_fun = fn ->
      send(test_pid, :server_fee_control_query)
      %{balance_snapshot: 0}
    end

    attrs = %{
      billing_account_id: "ba_1",
      provider: "openai",
      sku: "gpt-x",
      estimated_credits: 1,
      query_fun: query_fun,
      typed_sink: TypedSinkFake,
      row_context: %{
        "billing_account_id" => "ba_1",
        "surface" => "comma",
        "product_owner_type" => "workspace",
        "product_owner_id" => "w_1",
        "tenant_id" => "tenant_1",
        "group_id" => "group_1",
        "entrypoint" => "conversation_send",
        "actor_type" => "user"
      }
    }

    assert {:ok, first} = BillingCore.FeeControl.check_cached(attrs, server: name)
    assert first.query_performed == true
    assert_received :server_fee_control_query

    assert_receive {:typed_rows,
                    [
                      %{
                        "resource_kind" => "fee_control",
                        "would_block" => true,
                        "query_performed" => true
                      }
                    ]}

    assert {:ok, second} = BillingCore.FeeControl.check_cached(attrs, server: name)
    assert second.cache_hit == true
    assert second.query_performed == false
    refute_received :server_fee_control_query

    assert_receive {:typed_rows,
                    [
                      %{
                        "resource_kind" => "fee_control",
                        "cache_hit" => true,
                        "query_performed" => false
                      }
                    ]}
  end

  test "resource metering writes typed VM row before charging" do
    start_fee_control_server()

    interval_start = DateTime.from_unix!(1_780_000_000_000, :millisecond) |> DateTime.to_iso8601()
    interval_end = DateTime.from_unix!(1_780_000_005_000, :millisecond) |> DateTime.to_iso8601()

    state =
      State.new(
        pricing_catalog: [price(:vm, :runtime, "fly", "shared", 10)],
        grants: [grant("ba_1", 100)]
      )

    assert {:ok, charge, state} =
             ResourceMetering.meter_vm_interval(%{
               state: state,
               typed_sink: TypedSinkFake,
               billing_account_id: "ba_1",
               source_key: "vm_1",
               provider: "fly",
               sku: "shared",
               quantity: 5,
               duration_seconds: 5,
               interval_start_ms: 1_780_000_000_000,
               interval_end_ms: 1_780_000_005_000,
               env_id: "env_vm_1",
               sprite_name: "cloud-vm",
               metered_at: @now,
               owner_snapshot: owner()
             })

    assert charge.charged_credits == 50
    assert remaining(state.grants, "ba_1") == 50

    assert_receive {:typed_rows,
                    [%{"resource_kind" => "fee_control", "source_key" => "fee:vm:vm_1"}]}

    assert_receive {:typed_rows,
                    [
                      %{
                        "resource_kind" => "vm",
                        "duration_seconds" => 5,
                        "env_id" => "env_vm_1",
                        "sprite_name" => "cloud-vm",
                        "interval_start" => ^interval_start,
                        "interval_end" => ^interval_end
                      }
                    ]}
  end

  test "resource metering writes unattributed storage row without charging missing owner" do
    state = State.new()

    assert {:unattributed,
            %{"charge_status" => "unattributed", "billing_account_id" => "unattributed"}, ^state} =
             ResourceMetering.meter_storage_sample(%{
               state: state,
               typed_sink: TypedSinkFake,
               source_key: "storage_1",
               provider: "aws",
               sku: "standard",
               quantity: 10,
               bucket: "comma-storage",
               prefix: "agents/a1/",
               metered_at: @now
             })

    assert_receive {:typed_rows,
                    [
                      %{
                        "resource_kind" => "storage",
                        "byte_seconds" => 10,
                        "bucket" => "comma-storage",
                        "prefix" => "agents/a1/"
                      }
                    ]}
  end

  test "resource metering does not charge storage when tier is unknown" do
    state =
      State.new(
        grants: [grant("ba_1", 100)],
        pricing_catalog: [price(:storage, :byte_second, "aws", "unknown", 10)]
      )

    assert {:pending_pricing,
            %{"charge_status" => "pending_pricing", "billing_account_id" => "ba_1"}, ^state} =
             ResourceMetering.meter_storage_sample(%{
               state: state,
               typed_sink: TypedSinkFake,
               billing_account_id: "ba_1",
               source_key: "storage_unknown",
               provider: "aws",
               sku: "unknown",
               quantity: 10,
               bucket: "comma-storage",
               prefix: "agents/a1/",
               metered_at: @now,
               owner_snapshot: owner()
             })

    assert_receive {:typed_rows,
                    [
                      %{
                        "resource_kind" => "storage",
                        "charge_status" => "pending_pricing",
                        "storage_tier" => "unknown"
                      }
                    ]}
  end

  defp meter_event(attrs) do
    Map.merge(
      %{
        billing_account_id: "ba_1",
        source_key: "src_1",
        provider: "openai",
        sku: "gpt-x",
        quantity: 1,
        metered_at: @now
      },
      attrs
    )
  end

  defp price(resource_kind, component, provider, sku, usd_micros_per_unit) do
    %{
      resource_kind: resource_kind,
      component: component,
      provider: provider,
      sku: sku,
      usd_micros_per_unit: usd_micros_per_unit,
      effective_at: @now,
      version: "#{resource_kind}:#{component}:v1"
    }
  end

  defp owner do
    %{
      "billing_account_id" => "ba_1",
      "surface" => "bridge",
      "product_owner_type" => "organization",
      "product_owner_id" => "org_1",
      "salix_tenant_id" => "tenant_1",
      "salix_group_id" => "group_1"
    }
  end

  defp grant(account_id, credits) do
    %{
      id: "grant_#{account_id}",
      billing_account_id: account_id,
      remaining_credits: credits,
      expires_at: ~U[2026-06-18 00:00:00Z]
    }
  end

  defp remaining(grants, account_id) do
    grants
    |> Enum.find(&(&1.billing_account_id == account_id))
    |> case do
      nil -> 0
      grant -> Map.get(grant, :remaining_credits, 0)
    end
  end

  defp flush_sql_queries(acc \\ []) do
    receive do
      {:sql_query, query, params} -> flush_sql_queries([{query, params} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp restore_billing_env(key, nil), do: Application.delete_env(:billing_core, key)
  defp restore_billing_env(key, value), do: Application.put_env(:billing_core, key, value)

  defp agent_observation_run_fact do
    %{
      source: "test",
      source_key: "run:timeout",
      entrypoint: "agent_run",
      surface: "comma",
      tenant_id: "tenant_1",
      group_id: "group_1",
      actor_type: "user",
      status: "completed",
      duration_ms: 1,
      started_at: ~U[2026-07-08 00:00:00Z]
    }
  end

  defp find_query(queries, first, second \\ nil) do
    Enum.find(queries, fn {query, _params} ->
      String.contains?(query, first) and (is_nil(second) or String.contains?(query, second))
    end)
  end

  defp start_fee_control_server do
    unless Process.whereis(BillingCore.FeeControl.Server) do
      start_supervised!(BillingCore.FeeControl.Server)
    end

    :ok
  end

  # Pricing and row-projection assertions run at the delivery boundary.
  # LLMUsageSinkTest covers the production hook's asynchronous handoff.
  defp deliver_llm(fact), do: LLMMetering.deliver(LLMMetering.usage_row(fact), fact)
end
