defmodule SalixIM.SlackThreadRouteOwnerTest do
  use ExUnit.Case, async: false

  alias SalixIM.Provider.Slack.ThreadRouteOwner
  alias SalixIM.Triage.SlackEffectAdapter
  alias SalixStore.{CasRecord, Keys, S3, ULID}

  setup do
    previous_backend = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, S3.Fake)

    if Process.whereis(S3.Fake) do
      S3.Fake.reset()
    else
      start_supervised!(S3.Fake)
    end

    on_exit(fn ->
      if is_nil(previous_backend) do
        Application.delete_env(:salix_store, :s3_backend)
      else
        Application.put_env(:salix_store, :s3_backend, previous_backend)
      end
    end)

    :ok
  end

  test "owner-specific claims are immutable and exact duplicates are idempotent" do
    scope = route_scope("root-claim")
    claim_identity = String.duplicate("a", 64)

    assert ThreadRouteOwner.lookup(scope) == :unbound
    assert ThreadRouteOwner.claim_triage(scope, claim_identity) == {:ok, :triage}
    assert ThreadRouteOwner.lookup(scope) == {:ok, :triage}
    assert ThreadRouteOwner.verify_claim(scope, :triage, claim_identity) == {:ok, :triage}

    assert [key] = S3.Fake.put_log()
    assert {:ok, claimed} = CasRecord.get(key)

    assert Map.keys(claimed) |> Enum.sort() ==
             Enum.sort([
               "schema",
               "owner",
               "tenant_id",
               "group_id",
               "connect_id",
               "connect_generation",
               "workspace_id",
               "channel_id",
               "root_thread_ts",
               "claim_identity",
               "claimed_at_ms",
               "effect"
             ])

    assert claimed["schema"] == "comma.slack-thread-route-owner.v4"
    assert claimed["owner"] == "triage"
    assert claimed["tenant_id"] == scope["tenant_id"]
    assert claimed["group_id"] == scope["group_id"]
    assert claimed["connect_id"] == scope["connect_id"]
    assert claimed["connect_generation"] == scope["connect_generation"]
    assert claimed["workspace_id"] == scope["workspace_id"]
    assert claimed["channel_id"] == scope["channel_id"]
    assert claimed["root_thread_ts"] == scope["root_thread_ts"]
    assert claimed["claim_identity"] == claim_identity
    assert is_integer(claimed["claimed_at_ms"])
    assert is_nil(claimed["effect"])

    S3.Fake.reset_put_log()

    assert ThreadRouteOwner.claim_triage(scope, claim_identity) == {:ok, :triage}
    assert CasRecord.get(key) == {:ok, claimed}

    assert ThreadRouteOwner.claim_triage(scope, String.duplicate("b", 64)) ==
             {:conflict, :triage}

    assert ThreadRouteOwner.verify_claim(scope, :triage, String.duplicate("b", 64)) ==
             {:conflict, :triage}

    assert ThreadRouteOwner.verify_claim(scope, :legacy, claim_identity) ==
             {:conflict, :triage}

    assert ThreadRouteOwner.claim_legacy(scope, claim_identity) == {:conflict, :triage}
    assert CasRecord.get(key) == {:ok, claimed}
  end

  test "a final Triage effect reservation and explicit Task handover share one CAS fence" do
    scope = route_scope("task-handover")
    triage_identity = String.duplicate("e", 64)
    effect_identity = String.duplicate("f", 64)

    assert {:ok, task_identity} =
             ThreadRouteOwner.task_claim_identity(scope, "cnv_existing_task")

    assert {:ok, :triage} = ThreadRouteOwner.claim_triage(scope, triage_identity)

    assert :provider_effect_completed =
             ThreadRouteOwner.with_triage_effect(
               scope,
               triage_identity,
               effect_identity,
               fn reservation ->
                 assert reservation.claim_identity == triage_identity
                 assert ThreadRouteOwner.claim_task(scope, task_identity) == {:ok, :task}
                 assert ThreadRouteOwner.lookup_claim(scope) == {:ok, :task, task_identity}
                 :provider_effect_completed
               end
             )

    # The already-started effect may finish after Task owns the route, but no
    # new Triage effect can enter after the takeover.
    assert {:conflict, :task} =
             ThreadRouteOwner.with_triage_effect(
               scope,
               triage_identity,
               String.duplicate("0", 64),
               fn _reservation -> :unexpected_second_effect end
             )

    assert {:ok, :task} = ThreadRouteOwner.claim_task(scope, task_identity)
    assert ThreadRouteOwner.lookup_claim(scope) == {:ok, :task, task_identity}
    assert ThreadRouteOwner.verify_claim(scope, :triage, triage_identity) == {:conflict, :task}
  end

  test "the same effect identity cannot enter the provider critical section twice" do
    scope = route_scope("same-effect-identity")
    triage_identity = String.duplicate("7", 64)
    effect_identity = String.duplicate("8", 64)
    parent = self()

    assert {:ok, :triage} = ThreadRouteOwner.claim_triage(scope, triage_identity)

    first =
      Task.async(fn ->
        ThreadRouteOwner.with_triage_effect(
          scope,
          triage_identity,
          effect_identity,
          fn _reservation ->
            send(parent, {:effect_entered, self()})
            receive do: (:release -> :released)
          end
        )
      end)

    assert_receive {:effect_entered, first_pid}

    assert {:busy, :triage} =
             ThreadRouteOwner.with_triage_effect(
               scope,
               triage_identity,
               effect_identity,
               fn _reservation -> :second_holder_entered end
             )

    send(first_pid, :release)
    assert Task.await(first) == :released
  end

  test "a live provider effect never expires into an overlapping replacement" do
    scope = route_scope("live-effect-does-not-expire")
    triage_identity = String.duplicate("a", 64)
    first_effect_identity = String.duplicate("b", 64)
    parent = self()

    assert {:ok, :triage} = ThreadRouteOwner.claim_triage(scope, triage_identity)

    first =
      Task.async(fn ->
        ThreadRouteOwner.with_triage_effect(
          scope,
          triage_identity,
          first_effect_identity,
          fn _reservation ->
            send(parent, {:live_effect_entered, self()})
            receive do: (:release -> :released)
          end
        )
      end)

    assert_receive {:live_effect_entered, first_pid}

    key =
      Keys.ctl_im_slack_thread_route_owner(
        scope["group_id"],
        scope["workspace_id"],
        scope["channel_id"],
        scope["root_thread_ts"]
      )

    assert {:ok, _aged} =
             CasRecord.update(key, &put_in(&1, ["effect", "reserved_at_ms"], 0), create: false)

    assert {:busy, :triage} =
             ThreadRouteOwner.with_triage_effect(
               scope,
               triage_identity,
               String.duplicate("c", 64),
               fn _reservation -> :overlapping_effect_entered end
             )

    send(first_pid, :release)
    assert Task.await(first) == :released
  end

  test "a stale release cannot clear a newer reservation for the same logical effect" do
    scope = route_scope("stale-release-fenced")
    triage_identity = String.duplicate("d", 64)
    effect_identity = String.duplicate("e", 64)
    parent = self()

    assert {:ok, :triage} = ThreadRouteOwner.claim_triage(scope, triage_identity)

    first =
      Task.async(fn ->
        ThreadRouteOwner.with_triage_effect(
          scope,
          triage_identity,
          effect_identity,
          fn reservation ->
            send(parent, {:first_reservation_entered, self(), reservation})
            receive do: (:release -> :first_released)
          end
        )
      end)

    assert_receive {:first_reservation_entered, first_pid, first_reservation}

    key =
      Keys.ctl_im_slack_thread_route_owner(
        scope["group_id"],
        scope["workspace_id"],
        scope["channel_id"],
        scope["root_thread_ts"]
      )

    newer_reservation_identity = String.duplicate("9", 64)

    assert newer_reservation_identity != first_reservation.reservation_identity

    assert {:ok, replaced} =
             CasRecord.update(
               key,
               fn current ->
                 put_in(current, ["effect"], %{
                   "schema" => "comma.slack-thread-route-effect.v2",
                   "identity" => effect_identity,
                   "reservation_identity" => newer_reservation_identity,
                   "state" => "inflight",
                   "reserved_at_ms" => current["effect"]["reserved_at_ms"] + 1
                 })
               end,
               create: false
             )

    send(first_pid, :release)
    assert Task.await(first) == :first_released

    assert {:ok, after_stale_release} = CasRecord.get(key)
    assert after_stale_release == replaced
    assert after_stale_release["effect"]["reservation_identity"] == newer_reservation_identity

    assert {:busy, :triage} =
             ThreadRouteOwner.with_triage_effect(
               scope,
               triage_identity,
               String.duplicate("f", 64),
               fn _reservation -> :third_reservation_entered end
             )
  end

  test "explicit Task immediately claims while an earlier provider effect is still live" do
    scope = route_scope("immediate-task-handover")
    triage_identity = String.duplicate("2", 64)
    effect_identity = String.duplicate("3", 64)
    parent = self()

    assert {:ok, task_identity} =
             ThreadRouteOwner.task_claim_identity(scope, "cnv_immediate_task_handover")

    assert {:ok, :triage} = ThreadRouteOwner.claim_triage(scope, triage_identity)

    effect =
      Task.async(fn ->
        ThreadRouteOwner.with_triage_effect(
          scope,
          triage_identity,
          effect_identity,
          fn _reservation ->
            send(parent, {:live_effect_before_task, self()})
            receive do: (:release -> :released)
          end
        )
      end)

    assert_receive {:live_effect_before_task, effect_pid}

    assert ThreadRouteOwner.claim_task(scope, task_identity) == {:ok, :task}

    assert ThreadRouteOwner.lookup_claim(scope) == {:ok, :task, task_identity}
    send(effect_pid, :release)

    assert Task.await(effect) == :released
  end

  test "Task handover stays immediate during provider I/O and local completion" do
    scope = route_scope("final-effect-only")
    triage_identity = String.duplicate("9", 64)
    parent = self()

    assert {:ok, task_identity} =
             ThreadRouteOwner.task_claim_identity(scope, "cnv_final_effect_only")

    assert {:ok, :triage} = ThreadRouteOwner.claim_triage(scope, triage_identity)

    claim = %{
      obligation_id: "triage-product-" <> String.duplicate("a", 64),
      claim_token: "triage-product-claim-final-effect-only",
      payload: %{
        "communication" => %{"kind" => "reply", "text" => "Best-effort Triage reply"}
      }
    }

    assert {:ok, %{outcome: :applied, external_writes: 1}} =
             SlackEffectAdapter.apply(claim,
               freshness_port: __MODULE__.RouteFreshPort,
               reply_port: __MODULE__.TaskCompetingReplyPort,
               port_opts: [
                 test_pid: parent,
                 scope: scope,
                 triage_identity: triage_identity,
                 task_identity: task_identity
               ]
             )

    assert_receive {:task_claim_during_provider_write, {:ok, :task}}
    assert_receive {:task_claim_during_local_completion, {:ok, :task}}
    assert {:ok, :task} = ThreadRouteOwner.claim_task(scope, task_identity)
  end

  test "a crashed final-effect holder never strands explicit Task handover" do
    scope = route_scope("crashed-effect-holder")
    triage_identity = String.duplicate("4", 64)
    effect_identity = String.duplicate("5", 64)
    parent = self()

    assert {:ok, task_identity} =
             ThreadRouteOwner.task_claim_identity(scope, "cnv_crash_recovery")

    assert {:ok, :triage} = ThreadRouteOwner.claim_triage(scope, triage_identity)

    holder =
      spawn(fn ->
        ThreadRouteOwner.with_triage_effect(
          scope,
          triage_identity,
          effect_identity,
          fn _reservation ->
            send(parent, {:crashed_effect_entered, self()})
            Process.sleep(:infinity)
          end
        )
      end)

    assert_receive {:crashed_effect_entered, ^holder}
    Process.exit(holder, :kill)

    assert {:ok, :task} = ThreadRouteOwner.claim_task(scope, task_identity)
    assert ThreadRouteOwner.lookup_claim(scope) == {:ok, :task, task_identity}
  end

  defmodule RouteFreshPort do
    def check(_claim, opts) do
      scope = Keyword.fetch!(opts, :scope)
      triage_identity = Keyword.fetch!(opts, :triage_identity)

      case ThreadRouteOwner.verify_claim(scope, :triage, triage_identity) do
        {:ok, :triage} ->
          {:ok,
           %{
             status: :fresh,
             authority_ref: triage_identity,
             route_scope: scope,
             route_claim_identity: triage_identity
           }}

        _other ->
          {:ok, %{status: :stale, reason: :source_route_changed}}
      end
    end
  end

  defmodule TaskCompetingReplyPort do
    def lookup(_claim, _opts), do: {:ok, :not_delivered}
    def prepare(claim, _opts), do: {:ok, %{operation_ref: claim.obligation_id}}

    def deliver(_claim, prepared, opts) do
      task_claim =
        ThreadRouteOwner.claim_task(
          Keyword.fetch!(opts, :scope),
          Keyword.fetch!(opts, :task_identity)
        )

      send(Keyword.fetch!(opts, :test_pid), {:task_claim_during_provider_write, task_claim})

      {:ok, {:confirmed, prepared.operation_ref}}
    end

    def complete(_claim, _prepared, {:confirmed, operation_ref}, opts) do
      task_claim =
        ThreadRouteOwner.claim_task(
          Keyword.fetch!(opts, :scope),
          Keyword.fetch!(opts, :task_identity)
        )

      send(Keyword.fetch!(opts, :test_pid), {:task_claim_during_local_completion, task_claim})

      {:ok,
       %{
         operation_ref: operation_ref,
         channel_id: "C-final-effect-only",
         message_ts: "101.000001",
         already_delivered: false,
         external_writes: 1
       }}
    end
  end

  test "a deployed v2 owner is upgraded when its first final effect is reserved" do
    scope = route_scope("legacy-v2-upgrade")
    claim_identity = String.duplicate("1", 64)
    effect_identity = String.duplicate("2", 64)

    key =
      Keys.ctl_im_slack_thread_route_owner(
        scope["group_id"],
        scope["workspace_id"],
        scope["channel_id"],
        scope["root_thread_ts"]
      )

    assert {:ok, _legacy} =
             CasRecord.create(
               key,
               Map.merge(scope, %{
                 "schema" => "comma.slack-thread-route-owner.v2",
                 "owner" => "triage",
                 "claim_identity" => claim_identity,
                 "claimed_at_ms" => 1
               })
             )

    assert :ok =
             ThreadRouteOwner.with_triage_effect(
               scope,
               claim_identity,
               effect_identity,
               fn reservation ->
                 assert reservation.claim_identity == claim_identity
                 :ok
               end
             )

    assert {:ok, upgraded} = CasRecord.get(key)
    assert upgraded["schema"] == "comma.slack-thread-route-owner.v4"
    assert upgraded["effect"] == nil
  end

  test "legacy claims use the same owner record and malformed or unavailable storage fails closed" do
    scope = route_scope("legacy-and-fail-closed")
    claim_identity = String.duplicate("c", 64)

    assert ThreadRouteOwner.claim_legacy(scope, claim_identity) == {:ok, :legacy}
    assert ThreadRouteOwner.lookup(scope) == {:ok, :legacy}

    assert [key] = S3.Fake.put_log()

    assert {:ok, _malformed} =
             CasRecord.update(key, &Map.put(&1, "raw_extra", "must-not-be-accepted"))

    assert ThreadRouteOwner.lookup(scope) == :unavailable
    assert ThreadRouteOwner.claim_legacy(scope, claim_identity) == :unavailable

    unavailable_scope = route_scope("storage-unavailable")
    assert ThreadRouteOwner.lookup(unavailable_scope) == :unbound

    S3.Fake.reset_read_log()
    :ok = S3.Fake.set_fault({:fail, 503, :get, :any})

    assert ThreadRouteOwner.lookup(unavailable_scope) == :unavailable
  end

  test "verified root callback identity is canonical, scope-bound, and closed" do
    scope = route_scope("verified-root")

    callback = %{
      "provider_event_id" => "Ev-verified-root",
      "callback_app_id" => "A-route-verified-root",
      "workspace_id" => scope["workspace_id"],
      "channel_id" => scope["channel_id"],
      "root_thread_ts" => scope["root_thread_ts"]
    }

    assert {:ok, identity} =
             ThreadRouteOwner.verified_root_claim_identity(scope, callback)

    assert Regex.match?(~r/\A[0-9a-f]{64}\z/, identity)

    assert ThreadRouteOwner.verified_root_claim_identity(
             Map.new(Enum.reverse(Map.to_list(scope))),
             Map.new(Enum.reverse(Map.to_list(callback)))
           ) == {:ok, identity}

    assert {:ok, different_callback_identity} =
             ThreadRouteOwner.verified_root_claim_identity(
               scope,
               Map.put(callback, "provider_event_id", "Ev-different-root")
             )

    refute different_callback_identity == identity

    for invalid_callback <- [
          Map.put(callback, "workspace_id", "T-other"),
          Map.put(callback, "channel_id", "C-other"),
          Map.put(callback, "root_thread_ts", "1787015000.999999"),
          Map.put(callback, "raw_extra", "must-not-be-hashed"),
          Map.delete(callback, "provider_event_id"),
          Map.put(callback, "provider_event_id", " "),
          Map.put(callback, "provider_event_id", "Ev-root\0ambiguous")
        ] do
      assert ThreadRouteOwner.verified_root_claim_identity(scope, invalid_callback) ==
               {:error, :invalid_verified_root_callback}
    end
  end

  test "an ambiguous create is recovered only by an external exact retry" do
    scope = route_scope("ambiguous-create")
    claim_identity = String.duplicate("d", 64)

    key =
      Keys.ctl_im_slack_thread_route_owner(
        scope["group_id"],
        scope["workspace_id"],
        scope["channel_id"],
        scope["root_thread_ts"]
      )

    assert :ok = S3.Fake.set_fault({:ambiguous_after, :put, key})
    assert ThreadRouteOwner.claim_triage(scope, claim_identity) == :unavailable
    assert {:ok, durable} = CasRecord.get(key)

    assert ThreadRouteOwner.claim_triage(scope, claim_identity) == {:ok, :triage}
    assert CasRecord.get(key) == {:ok, durable}
  end

  defp route_scope(suffix) do
    %{
      "tenant_id" => "ten-route-#{suffix}",
      "group_id" => "grp-route-#{suffix}",
      "connect_id" => "cnc-route-#{suffix}",
      "connect_generation" => ULID.generate(),
      "workspace_id" => "T-route-#{suffix}",
      "channel_id" => "C-route-#{suffix}",
      "root_thread_ts" => "1787015000.000001"
    }
  end
end
