defmodule SalixIM.SlackThreadRouteOwnerTest do
  require SystemsRuntime.Proc

  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle
  alias SalixIM.Provider.Slack.ThreadRouteOwner
  alias SalixIM.Triage.SlackEffectAdapter
  alias SalixStore.{CasRecord, Keys, S3, ULID}

  setup do
    previous_backend = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, S3.Fake)

    if SystemsRuntime.Proc.whereis(S3.Fake) do
      S3.Fake.reset()
    else
      start_supervised!(S3.Fake)
    end

    on_exit(fn ->
      if is_nil(previous_backend) do
        SystemsRuntime.delete_env(:salix_store, :s3_backend)
      else
        SystemsRuntime.put_env(:salix_store, :s3_backend, previous_backend)
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
    parent = SystemsRuntime.Proc.self()

    assert {:ok, :triage} = ThreadRouteOwner.claim_triage(scope, triage_identity)

    first =
      SystemsRuntime.Task.async(fn ->
        ThreadRouteOwner.with_triage_effect(
          scope,
          triage_identity,
          effect_identity,
          fn _reservation ->
            SystemsRuntime.Proc.send(parent, {:effect_entered, SystemsRuntime.Proc.self()})
            SystemsRuntime.Proc.receive(do: (:release -> :released))
          end
        )
      end)

    settle_receive({:effect_entered, first_pid})

    assert {:busy, :triage} =
             ThreadRouteOwner.with_triage_effect(
               scope,
               triage_identity,
               effect_identity,
               fn _reservation -> :second_holder_entered end
             )

    SystemsRuntime.Proc.send(first_pid, :release)
    assert settled_await(first) == :released
  end

  test "a live provider effect never expires into an overlapping replacement" do
    scope = route_scope("live-effect-does-not-expire")
    triage_identity = String.duplicate("a", 64)
    first_effect_identity = String.duplicate("b", 64)
    parent = SystemsRuntime.Proc.self()

    assert {:ok, :triage} = ThreadRouteOwner.claim_triage(scope, triage_identity)

    first =
      SystemsRuntime.Task.async(fn ->
        ThreadRouteOwner.with_triage_effect(
          scope,
          triage_identity,
          first_effect_identity,
          fn _reservation ->
            SystemsRuntime.Proc.send(parent, {:live_effect_entered, SystemsRuntime.Proc.self()})
            SystemsRuntime.Proc.receive(do: (:release -> :released))
          end
        )
      end)

    settle_receive({:live_effect_entered, first_pid})

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

    SystemsRuntime.Proc.send(first_pid, :release)
    assert settled_await(first) == :released
  end

  test "a stale release cannot clear a newer reservation for the same logical effect" do
    scope = route_scope("stale-release-fenced")
    triage_identity = String.duplicate("d", 64)
    effect_identity = String.duplicate("e", 64)
    parent = SystemsRuntime.Proc.self()

    assert {:ok, :triage} = ThreadRouteOwner.claim_triage(scope, triage_identity)

    first =
      SystemsRuntime.Task.async(fn ->
        ThreadRouteOwner.with_triage_effect(
          scope,
          triage_identity,
          effect_identity,
          fn reservation ->
            SystemsRuntime.Proc.send(
              parent,
              {:first_reservation_entered, SystemsRuntime.Proc.self(), reservation}
            )

            SystemsRuntime.Proc.receive(do: (:release -> :first_released))
          end
        )
      end)

    settle_receive({:first_reservation_entered, first_pid, first_reservation})

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

    SystemsRuntime.Proc.send(first_pid, :release)
    assert settled_await(first) == :first_released

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

      SystemsRuntime.Proc.send(
        Keyword.fetch!(opts, :test_pid),
        {:task_claim_during_provider_write, task_claim}
      )

      {:ok, {:confirmed, prepared.operation_ref}}
    end

    def complete(_claim, _prepared, {:confirmed, operation_ref}, opts) do
      task_claim =
        ThreadRouteOwner.claim_task(
          Keyword.fetch!(opts, :scope),
          Keyword.fetch!(opts, :task_identity)
        )

      SystemsRuntime.Proc.send(
        Keyword.fetch!(opts, :test_pid),
        {:task_claim_during_local_completion, task_claim}
      )

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
