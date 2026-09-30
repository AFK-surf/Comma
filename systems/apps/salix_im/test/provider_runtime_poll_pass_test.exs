defmodule SalixIM.ProviderRuntimePollPassTest do
  @moduledoc """
  The polling timer callback must survive every enumeration outcome.

  `SalixIM.ProviderConnects` enumerates connects fail-closed and bounded, so a
  corpus past the scan cap, an unreadable record, or a transient store fault
  all reach the timer callback as `{:error, reason}`. A raising callback would
  take the process down on a fixed 5s interval, and the supervisor would
  restart straight into the same failure until restart intensity shut the
  subtree down — stopping Telegram/WeChat polling for the whole node. These
  tests pin the observable-outcome contract instead.
  """
  use ExUnit.Case, async: false

  alias SalixIM.ProviderRuntime
  alias SalixStore.{Keys, S3}

  @poll_event [:salix, :operation, :stop]

  setup do
    prev = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)

    on_exit(fn -> Application.put_env(:salix_store, :s3_backend, prev) end)

    handler = {__MODULE__, System.unique_integer([:positive])}
    parent = self()

    :ok =
      :telemetry.attach(
        handler,
        @poll_event,
        fn _event, measurements, metadata, _ ->
          # self() here is the process executing the pass (the poller under a
          # real GenServer, the test process for directly-driven callbacks) —
          # the correlation key the E2E scenario matches on.
          if metadata[:operation] == "provider_poll",
            do: send(parent, {:poll_pass, metadata, measurements, self()})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    # The state shape `init/1` builds; the callback is driven directly so the
    # assertions stay deterministic (no interval sleeping).
    {:ok, state: %{interval_ms: 5_000, providers: ["telegram", "wechat"]}}
  end

  defp seed_connect(group_id, connect_id, attrs \\ %{}) do
    record =
      Map.merge(
        %{
          "connect_id" => connect_id,
          "group_id" => group_id,
          "provider" => "telegram",
          "created_at" => 1_700_000_000_000
        },
        attrs
      )

    {:ok, _} = S3.put(Keys.ctl_im_connect(group_id, connect_id), Jason.encode!(record), [])
    :ok
  end

  test "an over-cap connect corpus reports scan_error instead of crashing the poller",
       %{state: state} do
    # The real incident: the bounded scan refuses a corpus past its cap, so
    # every pass returns {:error, :connect_scan_limit_exceeded}. One object
    # past the 1000-key cap is enough to force the continuation.
    for i <- 1..1001 do
      seed_connect("grp_scan", "cnc_#{String.pad_leading(Integer.to_string(i), 5, "0")}")
    end

    assert {:error, :connect_scan_limit_exceeded} =
             SalixIM.ProviderConnects.list_runtime_provider_connects(["telegram"])

    # The callback survives it, reschedules, and keeps its state.
    assert {:noreply, ^state} = ProviderRuntime.handle_info(:poll, state)
    assert_receive {:poll_pass, %{outcome: "scan_error", component: "salix_im"}, _, _}

    # And it stays alive across repeated failing passes — the restart-loop
    # shape would have died on the first one.
    assert {:noreply, ^state} = ProviderRuntime.handle_info(:poll, state)
    assert_receive {:poll_pass, %{outcome: "scan_error"}, _, _}
  end

  test "a store fault reports unavailable instead of crashing the poller", %{state: state} do
    seed_connect("grp_fault", "cnc_fault")

    :ok = SalixStore.S3.Fake.set_fault({:fail, 503, :list, Keys.ctl_im_connects_all_prefix()})

    assert {:noreply, ^state} = ProviderRuntime.handle_info(:poll, state)
    assert_receive {:poll_pass, %{outcome: "unavailable"}, _, _}
  end

  test "an unreadable connect record reports unavailable instead of crashing",
       %{state: state} do
    seed_connect("grp_bad", "cnc_bad")

    # Fail-closed enumeration: one unreadable record fails the whole pass.
    :ok =
      SalixStore.S3.Fake.set_fault({:fail, 503, :get, Keys.ctl_im_connect("grp_bad", "cnc_bad")})

    assert {:noreply, ^state} = ProviderRuntime.handle_info(:poll, state)
    assert_receive {:poll_pass, %{outcome: "unavailable"}, _, _}
  end

  test "an unanticipated crash inside the pass still emits (every pass emits)",
       %{state: state} do
    # S3.observe re-raises backend exceptions, so a raising backend reaches
    # the timer callback as an exception, not an {:error, _}. The catch
    # branch must be an outcome, never the one silent path.
    defmodule RaisingListS3 do
      def list(_prefix, _opts), do: raise("backend exploded")
    end

    prev = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, RaisingListS3)
    on_exit(fn -> Application.put_env(:salix_store, :s3_backend, prev) end)

    assert {:noreply, ^state} = ProviderRuntime.handle_info(:poll, state)
    assert_receive {:poll_pass, %{outcome: "error"}, _, _}

    # Alive across repeated crashing passes.
    assert {:noreply, ^state} = ProviderRuntime.handle_info(:poll, state)
    assert_receive {:poll_pass, %{outcome: "error"}, _, _}
  end

  test "an unexpected scan contract classifies as error, not the corpus action",
       %{state: state} do
    defmodule WeirdShapeListS3 do
      def list(_prefix, _opts), do: {:ok, :not_a_page}
    end

    prev = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, WeirdShapeListS3)
    on_exit(fn -> Application.put_env(:salix_store, :s3_backend, prev) end)

    assert {:noreply, ^state} = ProviderRuntime.handle_info(:poll, state)
    assert_receive {:poll_pass, %{outcome: "error"}, _, _}
  end

  test "a healthy empty corpus reports ok", %{state: state} do
    assert {:noreply, ^state} = ProviderRuntime.handle_info(:poll, state)
    assert_receive {:poll_pass, %{outcome: "ok"}, %{duration: duration}, _}
    assert duration >= 0
  end

  defmodule TicketedS3 do
    @moduledoc false
    # Acknowledgement-gated backend (the owner-chosen correlation structure):
    # every pass must request a uniquely-referenced ticket from the test
    # process and blocks until that exact ticket is granted with a mode. The
    # test therefore controls, one pass at a time, WHICH pass runs and HOW it
    # behaves — pass identity is the explicit ref, not an inference. A
    # suspended/killed poller can never request a new ticket, so a stale
    # "recovery" is structurally impossible to accept.
    def set_owner(pid), do: :persistent_term.put({__MODULE__, :owner}, pid)

    def list(prefix, opts) do
      ref = make_ref()
      send(:persistent_term.get({__MODULE__, :owner}), {:pass_request, ref, self()})

      receive do
        {:proceed, ^ref, :ok} -> SalixStore.S3.Fake.list(prefix, opts)
        {:proceed, ^ref, :raise} -> raise "backend exploded"
        {:proceed, ^ref, :throw} -> throw(:backend_threw)
        {:proceed, ^ref, :exit} -> exit(:backend_exited)
      end
    end

    defdelegate put(key, body, opts), to: SalixStore.S3.Fake
    defdelegate get(key, opts), to: SalixStore.S3.Fake
    defdelegate put_stream(key, stream, opts), to: SalixStore.S3.Fake
    defdelegate stream(key, opts), to: SalixStore.S3.Fake
    defdelegate head(key), to: SalixStore.S3.Fake
    defdelegate delete(key, opts), to: SalixStore.S3.Fake
    defdelegate multipart_create(key, opts), to: SalixStore.S3.Fake
    defdelegate multipart_upload_part(key, upload_id, part_number, body), to: SalixStore.S3.Fake
    defdelegate multipart_complete(key, upload_id, parts), to: SalixStore.S3.Fake
    defdelegate multipart_abort(key, upload_id), to: SalixStore.S3.Fake
  end

  # Grant one ticket to `poller` with `mode` and return its unique ref. The
  # request arrives only when a pass actually EXECUTES on that pid; granting
  # is the only way a pass can proceed, so ticket refs are the pass identity.
  defp grant_pass!(poller, mode) do
    assert_receive {:pass_request, ref, ^poller}, 2_000
    send(poller, {:proceed, ref, mode})
    ref
  end

  @tag :capture_log
  test "each crash kind: ticketed passes on one monitored pid — two faulted, one diagnostic each, then a strictly newer healthy pass" do
    reporter = Module.concat(__MODULE__, Reporter)

    start_supervised!(
      {TelemetryMetricsPrometheus.Core,
       name: reporter,
       metrics: SystemsObservability.Metrics.enabled_metrics([:salix]),
       start_async: false}
    )

    TicketedS3.set_owner(self())
    Application.put_env(:salix_store, :s3_backend, TicketedS3)

    kind_expectations = [
      raise: "(RuntimeError) backend exploded",
      throw: ":backend_threw",
      exit: ":backend_exited"
    ]

    for {kind, log_marker} <- kind_expectations do
      poller =
        start_supervised!(
          {SalixIM.ProviderRuntime, name: :"poll_pass_e2e_#{kind}", interval_ms: 20},
          id: {:poller, kind}
        )

      mref = Process.monitor(poller)

      # Readiness: the first ticketed pass on this pid completes healthy.
      ready_ref = grant_pass!(poller, :ok)
      assert_receive {:poll_pass, %{outcome: "ok"}, _, ^poller}, 2_000

      # Two faulted passes. One ticket granted at a time and its event
      # consumed before the next grant, so each {ref, diagnostic, event}
      # triple belongs to exactly one pass — one crash diagnostic per ref is
      # asserted by counting inside that pass's own captured segment.
      fault_refs =
        for _ <- 1..2 do
          {ref, log} =
            with_captured_log(fn ->
              ref = grant_pass!(poller, kind)
              assert_receive {:poll_pass, %{outcome: "error"}, _, ^poller}, 2_000
              ref
            end)

          occurrences = count_occurrences(log, "provider poll pass crashed")
          assert occurrences == 1, "expected exactly one crash diagnostic, got #{occurrences}"
          assert log =~ log_marker
          assert log =~ "provider_runtime_poll_pass_test.exs"
          ref
        end

      # Same monitored pid all the way through — no crash, no restart.
      refute_received {:DOWN, ^mref, :process, ^poller, _}
      assert Process.alive?(poller)

      # Recovery: a STRICTLY NEWER pass (fresh ref, granted only now) must
      # execute healthy on that same pid. A suspended poller could never
      # request this ticket, so this receive would time out — a stale
      # recovery cannot be accepted.
      heal_ref = grant_pass!(poller, :ok)
      assert heal_ref not in [ready_ref | fault_refs]
      assert_receive {:poll_pass, %{outcome: "ok"}, _, ^poller}, 2_000

      Process.demonitor(mref, [:flush])
      :ok = stop_supervised({:poller, kind})
      drain_pass_messages()
    end

    # Scrape boundary with the complete label set: 3 kinds x 2 faulted passes.
    scrape = TelemetryMetricsPrometheus.Core.scrape(reporter)

    assert [_, count] =
             Regex.run(
               ~r/salix_operations_total\{component="salix_im",operation="provider_poll",outcome="error",surface="system"\} (\d+)/,
               scrape
             )

    assert String.to_integer(count) >= 6

    assert scrape =~
             ~s(salix_operations_total{component="salix_im",operation="provider_poll",outcome="ok",surface="system"})
  end

  @tag :capture_log
  test "the reviewer's suspended-poller counterexample cannot pass under the ticket protocol" do
    # Round-4 counterexample, inverted into a regression: consume readiness,
    # run one faulted pass, then SUSPEND the poller before healing. A
    # suspended poller can never request a ticket, so no recovery pass
    # exists to grant — the protocol makes stale-recovery structurally
    # unacceptable rather than merely unlikely.
    TicketedS3.set_owner(self())
    Application.put_env(:salix_store, :s3_backend, TicketedS3)

    poller =
      start_supervised!(
        {SalixIM.ProviderRuntime, name: :poll_pass_suspended, interval_ms: 20},
        id: {:poller, :suspended}
      )

    _ready = grant_pass!(poller, :ok)
    assert_receive {:poll_pass, %{outcome: "ok"}, _, ^poller}, 2_000

    _fault = grant_pass!(poller, :raise)
    assert_receive {:poll_pass, %{outcome: "error"}, _, ^poller}, 2_000

    :ok = :sys.suspend(poller)

    # No pass can begin while suspended: no ticket request arrives, so there
    # is nothing to grant and no ok event can ever be produced or accepted.
    refute_receive {:pass_request, _, ^poller}, 300
    refute_receive {:poll_pass, %{outcome: "ok"}, _, ^poller}, 100

    :ok = :sys.resume(poller)
    # After resume the queued ticks request tickets again — real recovery.
    heal = grant_pass!(poller, :ok)
    assert is_reference(heal)
    assert_receive {:poll_pass, %{outcome: "ok"}, _, ^poller}, 2_000

    :ok = stop_supervised({:poller, :suspended})
    drain_pass_messages()
  end

  # capture_log returning both the fun's result and the captured output.
  defp with_captured_log(fun) do
    holder = self()

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        send(holder, {:captured_result, fun.()})
      end)

    receive do
      {:captured_result, result} -> {result, log}
    after
      0 -> flunk("captured fun did not report a result")
    end
  end

  defp count_occurrences(string, pattern) do
    string |> String.split(pattern) |> length() |> Kernel.-(1)
  end

  defp drain_pass_messages do
    receive do
      {:poll_pass, _, _, _} -> drain_pass_messages()
      {:pass_request, _, _} -> drain_pass_messages()
    after
      0 -> :ok
    end
  end

  test "poll_once itself still surfaces the enumeration error to other callers" do
    # The callback's tolerance must not hide the failure from the API: the
    # public function keeps returning the structured error.
    :ok = SalixStore.S3.Fake.set_fault({:fail, 503, :list, Keys.ctl_im_connects_all_prefix()})
    assert {:error, _} = ProviderRuntime.poll_once(["telegram"])
  end
end
