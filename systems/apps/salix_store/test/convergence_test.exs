defmodule SalixStore.ConvergenceTest do
  @moduledoc """
  The generic derived-storage convergence engine: paged/bounded passes with
  a durable resumable cursor, fail-closed record handling, monotonic
  converged? gating, page-batch mode, and honest telemetry on every
  attempt's true final outcome.
  """
  use ExUnit.Case, async: false

  alias SalixStore.{CasDirectory, Convergence, S3}

  @source "ctl/test_convergence_source/"
  @marker "ctl/test_convergence_marker.json"
  @dir "ctl/test_convergence_dir.json"

  defmodule PerRecord do
    @behaviour SalixStore.Convergence

    @impl true
    def name, do: "test_per_record"
    @impl true
    def source_prefix, do: "ctl/test_convergence_source/"
    @impl true
    def marker_key, do: "ctl/test_convergence_marker.json"
    @impl true
    def reconcile_ms, do: :timer.hours(1)

    @impl true
    def converge_record(key) do
      case SalixStore.S3.get(key) do
        {:ok, %{body: body}} ->
          case Jason.decode(body) do
            {:ok, %{"id" => id} = rec} ->
              # The changed/verified split the engine's converged count
              # relies on: an already-correct entry reports :unchanged.
              case CasDirectory.get("ctl/test_convergence_dir.json", id) do
                {:ok, ^rec} ->
                  :unchanged

                _ ->
                  case CasDirectory.put("ctl/test_convergence_dir.json", id, rec) do
                    {:ok, _} -> :changed
                    {:error, reason} -> {:error, reason}
                  end
              end

            {:ok, _} ->
              :skip

            {:error, reason} ->
              {:error, reason}
          end

        {:error, :not_found} ->
          :skip

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defmodule PerPage do
    @behaviour SalixStore.Convergence

    @impl true
    def name, do: "test_per_page"
    @impl true
    def source_prefix, do: "ctl/test_convergence_source/"
    @impl true
    def marker_key, do: "ctl/test_convergence_marker.json"

    @impl true
    def converge_page(keys) do
      with {:ok, recs} <- read_all(keys),
           {:ok, changed} <-
             CasDirectory.transact(
               "ctl/test_convergence_dir.json",
               fn entries ->
                 {next, changed} =
                   Enum.reduce(recs, {entries, 0}, fn rec, {acc, n} ->
                     case Map.get(acc, rec["id"]) do
                       ^rec -> {acc, n}
                       _ -> {Map.put(acc, rec["id"], rec), n + 1}
                     end
                   end)

                 {:commit, next, changed}
               end,
               materialize: true
             ) do
        {:ok,
         %{
           converged: changed,
           unchanged: length(recs) - changed,
           skipped: length(keys) - length(recs)
         }}
      end
    end

    defp read_all(keys) do
      Enum.reduce_while(keys, {:ok, []}, fn key, {:ok, acc} ->
        case SalixStore.S3.get(key) do
          {:ok, %{body: body}} ->
            case Jason.decode(body) do
              {:ok, %{"id" => _} = rec} -> {:cont, {:ok, [rec | acc]}}
              _ -> {:cont, {:ok, acc}}
            end

          {:error, :not_found} ->
            {:cont, {:ok, acc}}

          {:error, reason} ->
            {:halt, {:error, {:read_failed, key, reason}}}
        end
      end)
    end
  end

  setup do
    prev = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    Convergence.reset_converged_cache(PerRecord)
    Convergence.reset_converged_cache(PerPage)
    on_exit(fn -> Application.put_env(:salix_store, :s3_backend, prev) end)
    :ok
  end

  defp seed!(id, rec \\ nil) do
    {:ok, _} = S3.put(@source <> id <> ".json", Jason.encode!(rec || %{"id" => id}))
  end

  defp attach_telemetry! do
    ref = make_ref()
    parent = self()

    :telemetry.attach(
      {__MODULE__, ref},
      [:salix, :store, :convergence],
      fn _event, measurements, metadata, _config ->
        send(parent, {:convergence, ref, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)
    ref
  end

  test "a pass is page-bounded, cursor-resumable, and durably converged" do
    for id <- ~w(a b c), do: seed!(id)

    assert {:ok, :partial} = Convergence.ensure(PerRecord, pages_per_run: 1, page_size: 1)
    refute Convergence.converged?(PerRecord)

    assert {:ok, %{body: marker}} = S3.get(@marker)
    assert %{"cursor" => cursor, "completed_ever" => false} = Jason.decode!(marker)
    assert is_binary(cursor) and cursor != ""

    assert {:ok, :partial} = Convergence.ensure(PerRecord, pages_per_run: 1, page_size: 1)
    assert {:ok, :complete} = Convergence.ensure(PerRecord, pages_per_run: 2, page_size: 1)
    assert Convergence.converged?(PerRecord)

    assert {:ok, entries} = CasDirectory.entries(@dir)
    assert Map.keys(entries) |> Enum.sort() == ~w(a b c)

    # Fresh marker → ensure is one GET, no scan, and it reports the
    # REMAINING deadline so schedulers can align to the durable cadence.
    SalixStore.S3.Fake.reset_read_log()
    assert {:ok, :fresh, remaining} = Convergence.ensure(PerRecord)
    assert remaining > 0 and remaining <= :timer.hours(1)
    assert SalixStore.S3.Fake.read_log() == [{:get, @marker}]
  end

  test "a stale completed pass reconciles again" do
    seed!("a")
    assert {:ok, :complete} = Convergence.ensure(PerRecord)

    seed!("late")

    # Within the interval: no-op. Past it: a fresh pass picks up the drift.
    assert {:ok, :fresh, _remaining} = Convergence.ensure(PerRecord)
    assert {:error, :not_found} = CasDirectory.get(@dir, "late")

    future = System.system_time(:millisecond) + :timer.hours(2)
    assert {:ok, :complete} = Convergence.ensure(PerRecord, now: future)
    assert {:ok, _} = CasDirectory.get(@dir, "late")
  end

  test "an unreadable record fails the pass closed" do
    seed!("a")
    seed!("bad")
    SalixStore.S3.Fake.set_fault({:fail, 503, :get, @source <> "bad.json"})

    assert {:error, {:convergence_failed, "test_per_record", %{failed: 1}}} =
             Convergence.ensure(PerRecord)

    refute Convergence.converged?(PerRecord)

    assert {:ok, :complete} = Convergence.ensure(PerRecord)
    assert Convergence.converged?(PerRecord)
  end

  test "a cursor write failure aborts instead of silently losing progress" do
    seed!("a")
    seed!("b")
    SalixStore.S3.Fake.set_fault({:fail, 503, :put, @marker})

    assert {:error, {:progress_persist_failed, _}} =
             Convergence.ensure(PerRecord, pages_per_run: 2, page_size: 1)

    assert {:ok, :complete} = Convergence.ensure(PerRecord)
  end

  test "page-batch mode converges a page with one directory write" do
    for id <- ~w(a b c d), do: seed!(id)

    SalixStore.S3.Fake.reset_put_log()
    assert {:ok, :complete} = Convergence.ensure(PerPage, page_size: 2)

    assert {:ok, entries} = CasDirectory.entries(@dir)
    assert map_size(entries) == 4

    # 2 pages × 1 directory CAS each + progress/completion markers — never a
    # write per record.
    dir_puts = Enum.count(SalixStore.S3.Fake.put_log(), &(&1 == @dir))
    assert dir_puts == 2
  end

  test "a failing page batch fails the pass closed" do
    seed!("a")
    SalixStore.S3.Fake.set_fault({:fail, 503, :get, @source <> "a.json"})

    assert {:error, {:convergence_failed, "test_per_page", %{failed: 1}}} =
             Convergence.ensure(PerPage)
  end

  test "telemetry reports the true final outcome of every attempt" do
    ref = attach_telemetry!()
    seed!("a")

    # Marker READ fault → error event, not silence.
    SalixStore.S3.Fake.set_fault({:fail, 503, :get, @marker})
    assert {:error, _} = Convergence.ensure(PerRecord)
    assert_receive {:convergence, ^ref, _m1, %{name: "test_per_record", outcome: "error"}}

    # Clean walk whose completed_ever create-once fails → error, never ok,
    # and convergence stays unreported.
    SalixStore.S3.Fake.set_fault({:fail, 503, :put, @marker <> ".completed_ever"})
    assert {:error, {:completion_marker_failed, _}} = Convergence.ensure(PerRecord)
    assert_receive {:convergence, ^ref, _m2, %{outcome: "error"}}
    refute Convergence.converged?(PerRecord)

    # A durable completed_ever whose mutable-marker write fails still errors
    # (reconcile scheduling lost) but the monotonic fact stands.
    SalixStore.S3.Fake.set_fault({:fail, 503, :put, @marker})
    assert {:error, {:completion_marker_failed, _}} = Convergence.ensure(PerRecord)
    assert_receive {:convergence, ^ref, _m3, %{outcome: "error"}}
    assert Convergence.converged?(PerRecord)

    # The record was already folded in by the earlier (completion-failed)
    # walks, so the final clean pass verifies it: unchanged, not converged.
    assert {:ok, :complete} = Convergence.ensure(PerRecord)
    assert_receive {:convergence, ^ref, %{converged: 0, unchanged: 1}, %{outcome: "ok"}}
    assert Convergence.converged?(PerRecord)
  end

  test "a future completed_at is anomalous durable state and fails safe to a pass" do
    seed!("a")

    # A pass completed with a skewed clock durably stamps completed_at one
    # hour in the future (cross-node skew / backward clock correction).
    future = System.system_time(:millisecond) + :timer.hours(1)
    assert {:ok, :complete} = Convergence.ensure(PerRecord, now: future)

    seed!("late")

    # A normal ensure must NOT trust the future timestamp as fresh (it
    # would suppress healing for the whole skew) — it runs a pass.
    assert {:ok, :complete} = Convergence.ensure(PerRecord)
    assert {:ok, _} = CasDirectory.get(@dir, "late")
  end

  test "a clean verification pass reports unchanged, never converged (both callback modes)" do
    ref = attach_telemetry!()
    seed!("a")

    assert {:ok, :complete} = Convergence.ensure(PerRecord)
    assert_receive {:convergence, ^ref, %{converged: 1, unchanged: 0}, %{outcome: "ok"}}

    # Second pass over the same canonical state: everything verifies
    # already-correct. The exported healing volume must stay zero — a
    # healthy hourly scan can never look like inline writers losing data.
    future = System.system_time(:millisecond) + :timer.hours(2)
    assert {:ok, :complete} = Convergence.ensure(PerRecord, now: future)
    assert_receive {:convergence, ^ref, %{converged: 0, unchanged: 1}, %{outcome: "ok"}}

    # Page-batch mode: same split via the directory transaction's real
    # change count.
    later = System.system_time(:millisecond) + :timer.hours(4)
    assert {:ok, :complete} = Convergence.ensure(PerPage, now: later)
    assert_receive {:convergence, ^ref, %{converged: 0, unchanged: 1}, %{outcome: "ok"}}
  end

  defmodule LegacyReturn do
    @behaviour SalixStore.Convergence

    @impl true
    def name, do: "test_legacy_return"
    @impl true
    def source_prefix, do: "ctl/test_convergence_source/"
    @impl true
    def marker_key, do: "ctl/test_convergence_marker.json"

    # The retired pre-changed/unchanged shape — malformed under the current
    # contract.
    @impl true
    def converge_record(_key), do: :ok
  end

  defmodule NegativePage do
    @behaviour SalixStore.Convergence

    @impl true
    def name, do: "test_negative_page"
    @impl true
    def source_prefix, do: "ctl/test_convergence_source/"
    @impl true
    def marker_key, do: "ctl/test_convergence_marker.json"

    @impl true
    def converge_page(_keys), do: {:ok, %{converged: -3, skipped: 0}}
  end

  defmodule WorkUnitsPage do
    @behaviour SalixStore.Convergence

    @impl true
    def name, do: "test_work_units_page"
    @impl true
    def source_prefix, do: "ctl/test_convergence_source/"
    @impl true
    def marker_key, do: "ctl/test_convergence_marker.json"

    # Implementation-defined work units: more units than the page has
    # records (e.g. one record fanning out into several directory
    # mutations plus verified slots).
    @impl true
    def converge_page(_keys), do: {:ok, %{converged: 7, unchanged: 5, skipped: 3}}
  end

  test "page counters are implementation-defined work units, not record partitions" do
    ref = attach_telemetry!()
    seed!("a")

    # One source record, 15 units of reported work — valid under the
    # work-units contract (the counters are volume signals; only the
    # changed-vs-verified split is binding).
    assert {:ok, :complete} = Convergence.ensure(WorkUnitsPage)

    assert_receive {:convergence, ^ref, %{converged: 7, unchanged: 5, skipped: 3},
                    %{name: "test_work_units_page", outcome: "ok"}}
  end

  test "malformed callback results degrade to failed work, never a crash" do
    seed!("a")

    # A record callback returning the legacy :ok counts that record failed
    # (visible in telemetry) instead of raising through the Worker.
    assert {:error, {:convergence_failed, "test_legacy_return", %{failed: 1}}} =
             Convergence.ensure(LegacyReturn)

    # A page callback reporting an impossible count fails the page rather
    # than folding garbage into durable stats.
    assert {:error, {:convergence_failed, "test_negative_page", %{failed: 1}}} =
             Convergence.ensure(NegativePage)
  end

  defmodule SlowPass do
    @behaviour SalixStore.Convergence

    @impl true
    def name, do: "test_slow_pass"
    @impl true
    def source_prefix, do: "ctl/test_convergence_source/"
    @impl true
    def marker_key, do: "ctl/test_convergence_marker.json"

    @impl true
    def converge_record(_key) do
      Process.sleep(150)
      :changed
    end
  end

  test "fixed-delay: completed_at records the pass's actual completion, not its start" do
    seed!("a")

    before_pass = System.system_time(:millisecond)
    assert {:ok, :complete} = Convergence.ensure(SlowPass)

    assert {:ok, %{body: body}} = S3.get(@marker)
    %{"completed_at" => at} = Jason.decode!(body)

    # The 150ms pass must not durably age the next deadline: the anchor is
    # completion (>= start + pass runtime), never the pre-pass sample.
    assert at - before_pass >= 150
    assert at <= System.system_time(:millisecond)
  end

  test "fixed-delay: a slow marker read cannot inflate the remaining deadline" do
    seed!("a")
    assert {:ok, :complete} = Convergence.ensure(PerRecord, reconcile_ms: 1_000)

    # Age the durable anchor to 800ms of a 1000ms interval...
    {:ok, %{body: body}} = S3.get(@marker)
    marker = Jason.decode!(body)
    {:ok, _} = S3.put(@marker, Jason.encode!(Map.update!(marker, "completed_at", &(&1 - 800))))

    seed!("late")

    # ...and make the marker GET itself take 400ms. By the time the read
    # returns, the deadline has expired; sampling "now" before the read
    # would report ~200ms remaining and starve the late record.
    SalixStore.S3.Fake.set_fault({:delay, 400, :get, @marker})

    assert {:ok, :complete} = Convergence.ensure(PerRecord, reconcile_ms: 1_000)
    assert {:ok, _} = CasDirectory.get(@dir, "late")
  end

  defmodule MarkerRace do
    @behaviour SalixStore.Convergence

    @impl true
    def name, do: "test_marker_race"
    @impl true
    def source_prefix, do: "ctl/test_convergence_source/"
    @impl true
    def marker_key, do: "ctl/test_convergence_marker.json"

    # While this pass processes record "b", a concurrent worker (simulated
    # inline) advances the shared marker — the exact slow-worker interleaving.
    @impl true
    def converge_record(key) do
      if String.ends_with?(key, "/b.json") do
        {:ok, _} =
          SalixStore.S3.put(
            "ctl/test_convergence_marker.json",
            Jason.encode!(%{"cursor" => "ctl/test_convergence_source/z.json"}),
            []
          )
      end

      :changed
    end
  end

  test "a superseded pass cannot overwrite a newer pass's cursor" do
    for id <- ~w(a b c d), do: seed!(id)

    # The pass's page-boundary cursor write is CAS-chained on the marker
    # state it observed; the concurrent write during record "b" invalidates
    # that chain, so this pass aborts instead of clobbering the newer cursor.
    assert {:error, {:superseded_pass, _}} =
             Convergence.ensure(MarkerRace, pages_per_run: 4, page_size: 2)

    assert {:ok, %{body: marker}} = S3.get(@marker)
    assert %{"cursor" => "ctl/test_convergence_source/z.json"} = Jason.decode!(marker)
  end

  test "a stale worker overwriting the progress marker cannot regress convergence" do
    seed!("a")
    assert {:ok, :complete} = Convergence.ensure(PerRecord)
    assert Convergence.converged?(PerRecord)

    # A slow worker resumes with a pre-completion view and clobbers the
    # mutable marker (cursor + completed_ever=false) — the cross-pod
    # overwrite. The create-once completed_ever object is untouched, so a
    # fresh process (no cached flag) still reports converged.
    {:ok, _} =
      S3.put(
        @marker,
        Jason.encode!(%{"cursor" => @source <> "somewhere", "completed_ever" => false})
      )

    Convergence.reset_converged_cache(PerRecord)
    assert Convergence.converged?(PerRecord)

    # The stale cursor merely finishes an idempotent pass on the next ensure.
    assert {:ok, :complete} = Convergence.ensure(PerRecord)
    assert Convergence.converged?(PerRecord)
  end
end
