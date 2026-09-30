defmodule SalixMeet.Store do
  @moduledoc """
  CAS helpers over the single `meet/{id}/state.json` object. Unlike
  `SalixStore.Lease` — which keeps leadership in a
  *separate* lease key — a meeting **folds the lease into the state object
  itself**: `leader_node`, `lease_until`, and `epoch` live alongside the
  meeting's own fields. One ETag therefore fences both leadership renewal and
  state mutation, so a stale leader cannot smuggle a state write past a CAS it
  no longer owns.

  All mutations are conditional writes:

    * `create_once/2` — `if_none_match: "*"` create of an empty meeting.
    * `claim_leader/4` — `if_match` CAS that stamps `leader_node`/`lease_until`
      and bumps `epoch`, gated on staleness so exactly one node wins.
    * `set_join_requested/3` — stamps `join_requested_at` **at most once**
      (an idempotent no-op on the second attempt, preserving join-at-most-once).
    * `update_state/3` — CAS the caller-owned `state` map under a held ETag.

  Every successful read/write returns `{token, etag}` so the caller threads the
  live ETag forward; the ETag is the authority, never the clock (`lease_until`
  only gates steal eligibility, mirroring `SalixStore.Lease`).

  The group-scoped Triage read projection lives in PostgreSQL behind
  `SalixStore.MeetingGroupProjections`. New state claims its projection before
  the create-once S3 write; later state CAS operations never depend on the
  derived projection. Legacy state is projected by a later online release only
  after the projection-first writer has reached every environment; bounded
  reads remain disabled until that release seals readiness.
  """

  alias SalixMeet.FallbackMessageManifest
  alias SalixStore.{Keys, MeetingGroupProjections, S3}

  @type doc :: %{
          required(String.t()) => term()
        }
  @type result :: {:ok, doc(), SalixStore.S3.etag()} | {:error, term()}
  @type delivery_claim :: %{required(String.t()) => term()}
  @type activation_claim :: %{required(String.t()) => term()}

  @default_ttl 30_000
  @delivery_reclaim_after_ms 120_000
  @activation_reclaim_after_ms 120_000
  # Join re-claim mirrors the delivery reclaim precedent: a dispatching claim
  # older than the window is reclaimable, and the attempt budget is enforced
  # inside the claim CAS itself. Retry safety comes from the live-session
  # authority (RFC contract one), never from sender-side error classification.
  @join_reclaim_after_ms 120_000
  @join_max_attempts 5
  @terminal_statuses ~w(done failed cancelled)
  @max_projection_audit_page_size 100

  @doc "Create the meeting's state object once; `{:error, :exists}` if it already exists."
  @spec create_once(String.t(), keyword()) :: result()
  def create_once(id, opts \\ []) do
    now = opts[:now] || now_ms()

    doc = %{
      "id" => id,
      "epoch" => 0,
      "leader_node" => nil,
      "lease_until" => nil,
      "join_requested_at" => nil,
      "state" => opts[:state] || %{},
      "created_at" => now
    }

    with :ok <- ensure_group_projection(doc) do
      case S3.put(Keys.meet_state(id), Jason.encode!(doc), if_none_match: "*") do
        {:ok, %{etag: etag}} -> {:ok, doc, etag}
        {:error, :precondition_failed} -> {:error, :exists}
        other -> other
      end
    end
  end

  @doc "Read the meeting state object."
  @spec get(String.t()) :: result() | {:error, :not_found}
  def get(id) do
    case S3.get(Keys.meet_state(id)) do
      {:ok, %{body: body, etag: etag}} -> {:ok, Jason.decode!(body), etag}
      {:error, :not_found} = err -> err
      other -> other
    end
  end

  @doc "Read authoritative state already reached through the PostgreSQL group projection."
  @spec get_indexed(String.t()) :: result() | {:error, :not_found}
  def get_indexed(id) do
    case S3.get(Keys.meet_state(id)) do
      {:ok, %{body: body, etag: etag}} -> {:ok, Jason.decode!(body), etag}
      {:error, :not_found} = err -> err
      other -> other
    end
  end

  @doc "Backfill one existing meeting into the PostgreSQL group projection."
  @spec ensure_group_projection_for(String.t()) ::
          {:ok, :projected | :unscoped} | {:error, term()}
  def ensure_group_projection_for(id) do
    case get_indexed(id) do
      # The backfill is the repair path: it re-reads authoritative durable
      # state and never trusts a caller's proposed group.
      {:ok, doc, _etag} -> project_existing(doc)
      {:error, _reason} = error -> error
    end
  end

  @doc """
  CAS-claim (or renew) leadership by folding `leader_node`/`lease_until`/`epoch`
  into the state object. The claim is allowed only when the current holder is
  `node` (renew) or the lease is stale (steal); otherwise `{:error, {:held_by,
  node, until}}`. A losing CAS returns `{:error, :lost}` so the caller surrenders.
  """
  @spec claim_leader(String.t(), String.t(), SalixStore.S3.etag(), keyword()) ::
          result() | {:error, {:held_by, String.t() | nil, integer() | nil}} | {:error, :lost}
  def claim_leader(id, node, etag, opts \\ []) do
    now = opts[:now] || now_ms()
    ttl = opts[:ttl_ms] || @default_ttl

    with {:ok, doc, ^etag} <- read_at(id, etag) do
      cond do
        doc["leader_node"] == node -> cas_lead(id, doc, node, etag, now, ttl)
        stale?(doc, now) -> cas_lead(id, doc, node, etag, now, ttl)
        true -> {:error, {:held_by, doc["leader_node"], doc["lease_until"]}}
      end
    end
  end

  @doc """
  Stamp `join_requested_at` exactly once via CAS. If it is already set the call
  is an idempotent no-op returning the unchanged doc — join-at-most-once. A lost
  CAS returns `{:error, :lost}`.
  """
  @spec set_join_requested(String.t(), SalixStore.S3.etag(), keyword()) ::
          result() | {:error, :lost}
  def set_join_requested(id, etag, opts \\ []) do
    case request_join(id, etag, opts) do
      {:ok, doc, etag, _new?} -> {:ok, doc, etag}
      other -> other
    end
  end

  @doc """
  Stamp a join request exactly once and move the meeting state into joining.
  Returns whether this call created the request so callers can trigger the
  external meeting runtime only once.
  """
  @spec request_join(String.t(), SalixStore.S3.etag(), keyword()) ::
          {:ok, doc(), SalixStore.S3.etag(), boolean()} | {:error, :lost}
  def request_join(id, etag, opts \\ []) do
    at = opts[:at] || now_ms()

    with {:ok, doc, ^etag} <- read_at(id, etag) do
      case doc["join_requested_at"] do
        nil ->
          doc =
            doc
            |> Map.put("join_requested_at", at)
            |> Map.put("state", mark_join_requested(doc["state"] || %{}, at))

          case cas_put(id, doc, etag) do
            {:ok, doc, etag} -> {:ok, doc, etag, true}
            other -> other
          end

        _already ->
          {:ok, doc, etag, false}
      end
    end
  end

  @doc "Atomically claim the durable join-dispatch outbox for one caller."
  @spec claim_join_dispatch(String.t(), map(), keyword()) ::
          {:ok, :claimed | :dispatched, doc(), SalixStore.S3.etag(), map()}
          | {:error, term()}
  def claim_join_dispatch(id, claim, opts \\ []) when is_map(claim) do
    retries = Keyword.get(opts, :retries, 8)
    do_claim_join_dispatch(id, stringify(claim), opts, retries)
  end

  @doc "Checkpoint a claimed join dispatch as dispatched or failed under its generation fence."
  @spec checkpoint_join_dispatch(
          String.t(),
          String.t(),
          :dispatched | {:failed, term()},
          keyword()
        ) ::
          result() | {:error, :fenced | :lost}
  def checkpoint_join_dispatch(id, generation, outcome, opts \\ [])
      when is_binary(generation) and generation != "" do
    retries = Keyword.get(opts, :retries, 8)
    do_checkpoint_join_dispatch(id, generation, outcome, opts, retries)
  end

  @doc "Terminally abandon a pending calendar join without overriding an active or completed claim."
  @spec abandon_join_dispatch(String.t(), term(), keyword()) :: result() | {:error, term()}
  def abandon_join_dispatch(id, reason, opts \\ []) do
    retries = Keyword.get(opts, :retries, 8)
    do_abandon_join_dispatch(id, reason, opts, retries)
  end

  @doc """
  CAS the caller-owned `state` map under a held ETag. `fun` receives the current
  `state` map and returns the new one. `{:error, :lost}` on a losing CAS.
  """
  @spec update_state(String.t(), SalixStore.S3.etag(), (map() -> map())) ::
          result() | {:error, :lost}
  def update_state(id, etag, fun) when is_function(fun, 1) do
    with {:ok, doc, ^etag} <- read_at(id, etag) do
      cas_put(id, Map.put(doc, "state", fun.(doc["state"] || %{})), etag)
    end
  end

  @doc """
  Read-modify-write the caller-owned `state` map with a bounded CAS retry.
  Returns the updated document. This is for provider/runtime code that owns a
  meeting id but not a current ETag.
  """
  @spec update_state_retrying(String.t(), (map() -> map()), keyword()) ::
          result() | {:error, :lost}
  def update_state_retrying(id, fun, opts \\ []) when is_function(fun, 1) do
    retries = Keyword.get(opts, :retries, 8)
    update_state_retry(id, fun, retries)
  end

  @doc "List all known meeting ids."
  @spec list() :: {:ok, [String.t()]} | {:error, term()}
  def list do
    with {:ok, objects} <- S3.list_all(Keys.meet_states_prefix()) do
      ids =
        for %{key: "meet/" <> rest} <- objects,
            String.ends_with?(rest, "/state.json"),
            do: String.trim_trailing(rest, "/state.json")

      {:ok, ids}
    end
  end

  @doc "List one bounded page of authoritative meeting ids for projection auditing."
  @spec list_page(keyword()) ::
          {:ok, %{meeting_ids: [String.t()], continuation_token: String.t() | nil}}
          | {:error, :invalid | term()}
  def list_page(opts \\ [])

  def list_page(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      page_size = Keyword.get(opts, :page_size, 50)
      continuation_token = Keyword.get(opts, :continuation_token)

      valid? =
        Keyword.keys(opts) -- [:page_size, :continuation_token] == [] and
          is_integer(page_size) and page_size in 1..@max_projection_audit_page_size and
          (is_nil(continuation_token) or is_binary(continuation_token))

      if valid? do
        list_opts =
          [max_keys: page_size]
          |> maybe_put_continuation_token(continuation_token)

        with {:ok, %{objects: objects, next: next_token}} <-
               S3.list(Keys.meet_states_prefix(), list_opts) do
          meeting_ids =
            for %{key: "meet/" <> rest} <- objects,
                String.ends_with?(rest, "/state.json"),
                do: String.trim_trailing(rest, "/state.json")

          {:ok, %{meeting_ids: meeting_ids, continuation_token: next_token}}
        end
      else
        {:error, :invalid}
      end
    else
      {:error, :invalid}
    end
  end

  def list_page(_opts), do: {:error, :invalid}

  @doc """
  Claim terminal delivery for one meeting. This is the replacement for the old
  bridge-link claim row: the delivery claim lives inside the meeting state.
  """
  @spec claim_delivery(String.t(), String.t(), keyword()) ::
          {:ok, doc(), SalixStore.S3.etag(), delivery_claim()}
          | {:error, :not_terminal | :not_claimable | :lost}
  def claim_delivery(id, node, opts \\ []), do: do_claim_delivery(id, node, opts, 8)

  @doc """
  Claim the next work for a terminal meeting from one state read: summary
  publication before `published_at`, or router activation afterward. Keeping
  the selection in one CAS loop avoids rereading every historical published
  meeting on each delivery sweep.
  """
  @spec claim_terminal_work(String.t(), String.t(), keyword()) ::
          {:ok, :delivery, doc(), SalixStore.S3.etag(), delivery_claim()}
          | {:ok, :activation, doc(), SalixStore.S3.etag(), activation_claim()}
          | {:error, term()}
  def claim_terminal_work(id, node, opts \\ []),
    do: do_claim_terminal_work(id, node, opts, 8)

  @doc "Check that a delivery generation is still the active, unpublished claim."
  @spec check_delivery_claim(String.t(), delivery_claim()) :: :ok | {:error, term()}
  def check_delivery_claim(id, claim) do
    with {:ok, doc, _etag} <- get(id),
         true <- delivery_claim_matches?(doc["state"] || %{}, claim) do
      :ok
    else
      false -> {:error, :fenced}
      {:error, _} = err -> err
    end
  end

  @doc "CAS-merge delivery fields only while the supplied generation owns the claim."
  @spec checkpoint_delivery(String.t(), delivery_claim(), map(), keyword()) ::
          result() | {:error, :fenced | :lost}
  def checkpoint_delivery(id, claim, attrs, opts \\ []) when is_map(attrs) do
    update_delivery_state(
      id,
      claim,
      &put_delivery(&1, attrs),
      opts
    )
  end

  @doc "Refresh the active delivery claim's reclaim deadline under the same generation fence."
  @spec heartbeat_delivery(String.t(), delivery_claim(), keyword()) ::
          result() | {:error, :fenced | :lost}
  def heartbeat_delivery(id, claim, opts \\ []) do
    now = opts[:now] || now_ms()

    checkpoint_delivery(
      id,
      claim,
      %{"last_attempt_at" => now, "updated_at" => now},
      opts
    )
  end

  @doc "CAS-update meeting state only while the supplied delivery generation owns the claim."
  @spec update_delivery_state(String.t(), delivery_claim(), (map() -> map()), keyword()) ::
          result() | {:error, :fenced | :lost}
  def update_delivery_state(id, claim, fun, opts \\ []) when is_function(fun, 1) do
    retries = Keyword.get(opts, :retries, 8)

    if valid_delivery_claim?(claim) do
      do_update_delivery_state(id, stringify(claim), fun, retries)
    else
      {:error, :fenced}
    end
  end

  @doc "Record delivery failure only if the same claim still owns the delivery."
  @spec fail_delivery_retrying(String.t(), delivery_claim(), String.t(), keyword()) ::
          result() | {:error, :fenced | :lost}
  def fail_delivery_retrying(id, claim, error_text, opts \\ []) do
    now = opts[:now] || now_ms()

    update_delivery_state(
      id,
      claim,
      fn state ->
        delivery = stringify(state["delivery"] || %{})

        attrs = %{
          "status" => "failed",
          "error" => trim(error_text),
          "updated_at" => now
        }

        # The first failure timestamp anchors the bounded-retry time gate; a
        # later success leaves it behind harmlessly (the gate is only read
        # while the delivery is failing).
        attrs =
          if is_integer(delivery["first_failed_at"]),
            do: attrs,
            else: Map.put(attrs, "first_failed_at", now)

        # Optional retry backoff. Only failures that are known to be waiting
        # on something external (a disabled connect) set it; every other
        # failure stays immediately reclaimable, so the ordinary retry cadence
        # is unchanged. Always written so a later ordinary failure clears a
        # stale backoff instead of inheriting it.
        attrs =
          case opts[:retry_after_ms] do
            ms when is_integer(ms) and ms > 0 -> Map.put(attrs, "next_attempt_at", now + ms)
            _ -> Map.put(attrs, "next_attempt_at", nil)
          end

        put_delivery(state, attrs)
      end,
      opts
    )
  end

  @doc "Record a non-retryable delivery failure under the active generation fence."
  @spec fail_delivery_terminal(
          String.t(),
          delivery_claim(),
          String.t(),
          String.t(),
          keyword()
        ) :: result() | {:error, :fenced | :lost}
  def fail_delivery_terminal(id, claim, failure_kind, error_text, opts \\ []) do
    checkpoint_delivery(
      id,
      claim,
      %{
        "status" => "failed_terminal",
        "failure_kind" => trim(failure_kind),
        "error" => trim(error_text),
        "updated_at" => opts[:now] || now_ms()
      },
      opts
    )
  end

  @watchdog_cutoff_s 2 * 60 * 60

  @doc "The accepted maximum overtime (seconds) before the summary watchdog may terminalize."
  def watchdog_cutoff_s, do: @watchdog_cutoff_s

  @doc """
  Evaluate the summary-watchdog predicate against one meeting snapshot.

  The time threshold is a product cutoff — the accepted maximum overtime —
  never evidence that the meeting ended. Only meetings that really dispatched
  a join and were not abandoned by the calendar path are eligible; a document
  with none of the anchoring timestamps is `:no_anchor` (counted as stuck,
  never terminalized). All timestamp anchors are unix seconds.
  """
  @spec watchdog_eligibility(doc(), integer(), pos_integer()) ::
          :terminal
          | :not_dispatched
          | :abandoned
          | :no_anchor
          | :not_due
          | {:eligible, integer()}
  def watchdog_eligibility(doc, now_s, cutoff_s \\ @watchdog_cutoff_s) do
    doc = stringify(doc || %{})
    state = stringify(doc["state"] || %{})
    dispatch = stringify(state["join_dispatch"] || %{})

    cond do
      state["status"] in @terminal_statuses ->
        :terminal

      not (is_integer(doc["join_requested_at"]) or is_integer(state["join_requested_at"])) ->
        :not_dispatched

      join_abandoned?(state, dispatch) ->
        :abandoned

      true ->
        case watchdog_anchor_s(state) do
          nil ->
            :no_anchor

          anchor when now_s >= anchor + cutoff_s ->
            {:eligible, anchor + cutoff_s}

          _anchor ->
            :not_due
        end
    end
  end

  defp watchdog_anchor_s(state) do
    ~w(end_at left_at joined_at last_seen_live_at)
    |> Enum.map(&state[&1])
    |> Enum.filter(&is_integer/1)
    |> case do
      [] -> nil
      anchors -> Enum.max(anchors)
    end
  end

  @watchdog_probe_ttl_ms 60_000

  @doc """
  Claim the meeting-level watchdog probe fence.

  The probe-then-decide sequence must be serialized per meeting: without this
  fence, two delivery sweeps overlapping across a lost global lease could both
  probe, and an `unavailable` answer landing its CAS first would permanently
  terminalize a meeting whose other probe had just confirmed a live bot. The
  claim is taken before the probe; both decision writers
  (`refresh_runtime_liveness/3` and `mark_runtime_lost/2`) are fenced on the
  claimed generation, so exactly one probe's answer can act. A claim older
  than the probe TTL is stealable (its holder crashed mid-probe); the stale
  holder's late decision then loses the generation fence.

  Modeled in `tla/salix/MeetingWatchdogProbe.tla`: the claim/steal/fenced-
  decision transitions here must stay in sync with that spec. Safety is
  `NoKillOverCurrentLiveAnswer` and `NoKillAfterAnchor`; progress is the
  fault-free `EventuallySettled` theorem, where this TTL steal is the
  load-bearing recovery for a holder that crashed mid-probe
  (`_NoStealNoProgress` is its expected liveness counterexample).
  """
  @spec claim_watchdog_probe(String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def claim_watchdog_probe(id, node, opts \\ []), do: do_claim_watchdog_probe(id, node, opts, 8)

  defp do_claim_watchdog_probe(_id, _node, _opts, 0), do: {:error, :lost}

  defp do_claim_watchdog_probe(id, node, opts, retries) do
    now = opts[:now] || now_ms()
    now_s = opts[:now_s] || div(now, 1000)
    cutoff_s = opts[:cutoff_s] || @watchdog_cutoff_s
    probe_ttl = opts[:probe_ttl_ms] || @watchdog_probe_ttl_ms

    with {:ok, doc, etag} <- get(id) do
      state = stringify(doc["state"] || %{})
      probe = stringify(state["watchdog_probe"] || %{})

      cond do
        not match?({:eligible, _}, watchdog_eligibility(doc, now_s, cutoff_s)) ->
          {:error, {:watchdog_ineligible, watchdog_eligibility(doc, now_s, cutoff_s)}}

        is_integer(probe["claimed_at"]) and probe["claimed_at"] > now - probe_ttl ->
          {:error, :probe_held}

        true ->
          generation = SalixStore.Crypto.hex(:crypto.strong_rand_bytes(12))

          next_state =
            Map.put(state, "watchdog_probe", %{
              "node" => node,
              "generation" => generation,
              "claimed_at" => now
            })

          case cas_put(id, Map.put(doc, "state", next_state), etag) do
            {:ok, _doc, _etag} -> {:ok, generation}
            {:error, :lost} -> do_claim_watchdog_probe(id, node, opts, retries - 1)
            other -> other
          end
      end
    end
  end

  @doc """
  Record a definitely-live runtime answer under the probe fence, pushing the
  watchdog anchor forward and releasing the probe claim. A generation mismatch
  means another sweep stole the probe; the late answer is dropped as
  `{:error, :fenced}`. Modeled as the `LiveReadProceed`/`LiveReadDropped` and
  `LiveCas*` transitions of `tla/salix/MeetingWatchdogProbe.tla`.
  """
  def refresh_runtime_liveness(id, now_s, generation)
      when is_integer(now_s) and is_binary(generation) do
    with {:ok, doc, _etag} <- get(id),
         :ok <- require_watchdog_probe(doc, generation) do
      update_state_retrying(id, fn state ->
        state = stringify(state || %{})

        cond do
          state["status"] in @terminal_statuses ->
            state

          get_in(state, ["watchdog_probe", "generation"]) != generation ->
            state

          true ->
            state
            |> Map.put("last_seen_live_at", now_s)
            |> Map.delete("watchdog_probe")
        end
      end)
    end
  end

  defp require_watchdog_probe(doc, generation) do
    if get_in(stringify(doc["state"] || %{}), ["watchdog_probe", "generation"]) == generation,
      do: :ok,
      else: {:error, :fenced}
  end

  @doc """
  Terminalize one runtime-lost meeting under the watchdog predicate.

  The predicate is re-validated inside the CAS loop so a racing terminal event
  (or a liveness refresh) wins over a stale sweep decision. A meeting without
  a provider thread is terminalized with its delivery already closed as
  `failed_terminal` — publishing to a missing thread would only open a new
  retry loop. Modeled as the `KillReadProceed`/`KillReadDropped` and
  `KillCas*` transitions of `tla/salix/MeetingWatchdogProbe.tla`, whose
  `NoKillOverCurrentLiveAnswer` invariant is exactly the generation-fence
  requirement here.
  """
  @spec mark_runtime_lost(String.t(), keyword()) :: result() | {:error, term()}
  def mark_runtime_lost(id, opts \\ []), do: do_mark_runtime_lost(id, opts, 8)

  defp do_mark_runtime_lost(_id, _opts, 0), do: {:error, :lost}

  defp do_mark_runtime_lost(id, opts, retries) do
    now_s = opts[:now_s] || div(opts[:now] || now_ms(), 1000)
    cutoff_s = opts[:cutoff_s] || @watchdog_cutoff_s
    generation = Keyword.fetch!(opts, :generation)

    with {:ok, doc, etag} <- get(id),
         :ok <- require_watchdog_probe(doc, generation) do
      case watchdog_eligibility(doc, now_s, cutoff_s) do
        {:eligible, _deadline} ->
          state = stringify(doc["state"] || %{})

          next_state =
            state
            |> Map.delete("watchdog_probe")
            |> Map.put("status", "failed")
            |> Map.put("error", "meeting runtime lost before it reported completion")
            |> Map.put("watchdog", %{
              "reason" => "runtime_lost",
              "terminalized_at" => now_s
            })

          next_state =
            if provider_thread_present?(state) do
              next_state
            else
              put_delivery(next_state, %{
                "status" => "failed_terminal",
                "failure_kind" => "runtime_lost_no_thread",
                "error" => "meeting runtime lost; no provider thread to notify",
                "updated_at" => now_ms()
              })
            end

          case cas_put(id, Map.put(doc, "state", next_state), etag) do
            {:ok, _doc, _etag} = ok -> ok
            {:error, :lost} -> do_mark_runtime_lost(id, opts, retries - 1)
            other -> other
          end

        verdict ->
          {:error, {:watchdog_ineligible, verdict}}
      end
    end
  end

  defp provider_thread_present?(state) do
    case state["provider"] do
      "slack" ->
        trim(get_in(state, ["slack_ref", "channel_id"])) != "" and
          trim(get_in(state, ["slack_ref", "thread_ts"])) != ""

      "feishu" ->
        stringify(state["feishu_ref"] || %{}) |> map_size() > 0

      _other ->
        false
    end
  end

  @doc "Claim a durable post-publication router activation generation."
  @spec claim_activation(String.t(), String.t(), keyword()) ::
          {:ok, doc(), SalixStore.S3.etag(), activation_claim()}
          | {:error, term()}
  def claim_activation(id, node, opts \\ []), do: do_claim_activation(id, node, opts, 8)

  @doc "Check that an activation generation still owns the pending handoff."
  @spec check_activation_claim(String.t(), activation_claim()) :: :ok | {:error, term()}
  def check_activation_claim(id, claim) do
    with {:ok, doc, _etag} <- get(id),
         true <- activation_claim_matches?(doc["state"] || %{}, claim, id) do
      :ok
    else
      false -> {:error, :fenced}
      {:error, _} = err -> err
    end
  end

  @doc "Complete the exact activation generation as queued or intentionally skipped."
  @spec complete_activation(String.t(), activation_claim(), :queued | :skipped, keyword()) ::
          result() | {:error, :fenced | :lost}
  def complete_activation(id, claim, status, opts \\ []) when status in [:queued, :skipped] do
    now = opts[:now] || now_ms()

    update_activation_state(id, claim, fn state ->
      put_activation(state, %{
        "status" => Atom.to_string(status),
        "error" => "",
        "completed_at" => now,
        "updated_at" => now
      })
    end)
  end

  @doc "Record a retryable failure only for the exact activation generation."
  @spec fail_activation_retrying(String.t(), activation_claim(), String.t(), keyword()) ::
          result() | {:error, :fenced | :lost}
  def fail_activation_retrying(id, claim, error_text, opts \\ []) do
    now = opts[:now] || now_ms()

    update_activation_state(id, claim, fn state ->
      put_activation(state, %{
        "status" => "failed",
        "error" => trim(error_text),
        "updated_at" => now
      })
    end)
  end

  @doc false
  @spec activation_delivery_ready?(map(), String.t()) :: boolean()
  def activation_delivery_ready?(delivery, meeting_id) when is_map(delivery) do
    delivery = stringify(delivery)

    delivery["published_at"] not in [nil, "", false] or
      (delivery["status"] == "failed_terminal" and
         durable_full_summary_pointer?(delivery, meeting_id))
  end

  def activation_delivery_ready?(_delivery, _meeting_id), do: false

  # ---- internal ----

  defp do_claim_terminal_work(_id, _node, _opts, 0), do: {:error, :not_claimable}

  defp do_claim_terminal_work(id, node, opts, retries) do
    now = opts[:now] || now_ms()
    delivery_reclaim_after = opts[:reclaim_after_ms] || @delivery_reclaim_after_ms
    activation_reclaim_after = opts[:reclaim_after_ms] || @activation_reclaim_after_ms

    with {:ok, doc, etag} <- get(id) do
      state = stringify(doc["state"] || %{})
      delivery = stringify(state["delivery"] || %{})

      cond do
        state["status"] not in @terminal_statuses ->
          # The sweep is the only regular reader of every meeting; hand the
          # already-read snapshot back so the caller's watchdog can evaluate
          # stuck non-terminal meetings without a second GET per pass.
          {:error, {:not_terminal, doc}}

        activation_delivery_ready?(delivery, id) ->
          claim_activation_from_terminal_read(
            id,
            node,
            opts,
            retries,
            now,
            activation_reclaim_after,
            doc,
            etag,
            state,
            delivery
          )

        FallbackMessageManifest.repairable_terminal?(delivery, id) or
            delivery_claimable?(delivery, now, delivery_reclaim_after) ->
          claim_delivery_from_terminal_read(
            id,
            node,
            opts,
            retries,
            now,
            doc,
            etag,
            state,
            delivery
          )

        true ->
          {:error, :not_claimable}
      end
    end
  end

  defp claim_delivery_from_terminal_read(
         id,
         node,
         opts,
         retries,
         now,
         doc,
         etag,
         state,
         delivery
       ) do
    attempt_count = integer_or_zero(delivery["attempt_count"]) + 1

    claimed =
      put_delivery(state, %{
        "status" => "delivering",
        "error" => "",
        "attempt_count" => attempt_count,
        "last_attempt_at" => now,
        "claim_node" => node,
        "updated_at" => now
      })

    claim = %{"claim_node" => node, "attempt_count" => attempt_count}

    case cas_put(id, Map.put(doc, "state", claimed), etag) do
      {:error, :lost} -> do_claim_terminal_work(id, node, opts, retries - 1)
      {:ok, doc, etag} -> {:ok, :delivery, doc, etag, claim}
      other -> other
    end
  end

  defp claim_activation_from_terminal_read(
         id,
         node,
         opts,
         retries,
         now,
         reclaim_after,
         doc,
         etag,
         state,
         delivery
       ) do
    case claim_activation_once(id, node, now, reclaim_after, doc, etag, state, delivery) do
      {:retry, :lost} ->
        do_claim_terminal_work(id, node, opts, retries - 1)

      {:ok, doc, etag, claim} ->
        {:ok, :activation, doc, etag, claim}

      {:error, :not_claimable} = error ->
        error

      {:error, reason} ->
        {:error, {:activation, reason}}
    end
  end

  defp do_claim_delivery(_id, _node, _opts, 0), do: {:error, :not_claimable}

  defp do_claim_delivery(id, node, opts, retries) do
    now = opts[:now] || now_ms()
    reclaim_after = opts[:reclaim_after_ms] || @delivery_reclaim_after_ms

    with {:ok, doc, etag} <- get(id) do
      state = doc["state"] || %{}
      delivery = state["delivery"] || %{}

      cond do
        state["status"] not in @terminal_statuses ->
          {:error, :not_terminal}

        delivery["published_at"] ->
          {:error, :not_claimable}

        FallbackMessageManifest.repairable_terminal?(delivery, id) or
            delivery_claimable?(delivery, now, reclaim_after) ->
          claimed =
            state
            |> put_delivery(%{
              "status" => "delivering",
              "error" => "",
              "attempt_count" => (delivery["attempt_count"] || 0) + 1,
              "last_attempt_at" => now,
              "claim_node" => node,
              "updated_at" => now
            })

          claim = %{
            "claim_node" => node,
            "attempt_count" => get_in(claimed, ["delivery", "attempt_count"])
          }

          case cas_put(id, Map.put(doc, "state", claimed), etag) do
            {:error, :lost} -> do_claim_delivery(id, node, opts, retries - 1)
            {:ok, doc, etag} -> {:ok, doc, etag, claim}
            other -> other
          end

        true ->
          {:error, :not_claimable}
      end
    end
  end

  defp delivery_claimable?(delivery, now, reclaim_after) do
    case delivery["status"] do
      nil -> true
      "" -> true
      # A failed delivery is immediately reclaimable unless it recorded an
      # explicit backoff (see `fail_delivery_retrying/4`). The backoff can
      # only delay a retry, never cancel one: it is re-evaluated every sweep
      # and the bounded-retry gates still govern convergence.
      "failed" -> (delivery["next_attempt_at"] || 0) <= now
      "delivering" -> (delivery["last_attempt_at"] || 0) <= now - reclaim_after
      _ -> false
    end
  end

  defp do_claim_activation(_id, _node, _opts, 0), do: {:error, :not_claimable}

  defp do_claim_activation(id, node, opts, retries) do
    now = opts[:now] || now_ms()
    reclaim_after = opts[:reclaim_after_ms] || @activation_reclaim_after_ms

    with {:ok, doc, etag} <- get(id) do
      state = stringify(doc["state"] || %{})
      delivery = stringify(state["delivery"] || %{})

      case claim_activation_once(id, node, now, reclaim_after, doc, etag, state, delivery) do
        {:retry, :lost} -> do_claim_activation(id, node, opts, retries - 1)
        other -> other
      end
    end
  end

  defp claim_activation_once(id, node, now, reclaim_after, doc, etag, state, delivery) do
    activation = stringify(delivery["activation"] || %{})

    cond do
      trim(node) == "" ->
        {:error, :not_claimable}

      not activation_delivery_ready?(delivery, id) ->
        {:error, :not_claimable}

      not activation_claimable?(delivery, activation, now, reclaim_after) ->
        {:error, :not_claimable}

      true ->
        attempt_count = integer_or_zero(activation["attempt_count"]) + 1

        claimed =
          state
          |> maybe_upgrade_legacy_terminal_notes(delivery, now)
          |> put_activation(%{
            "status" => "activating",
            "error" => "",
            "attempt_count" => attempt_count,
            "claim_node" => trim(node),
            "last_attempt_at" => now,
            "updated_at" => now
          })

        claim = %{"claim_node" => trim(node), "attempt_count" => attempt_count}

        case cas_put(id, Map.put(doc, "state", claimed), etag) do
          {:error, :lost} -> {:retry, :lost}
          {:ok, doc, etag} -> {:ok, doc, etag, claim}
          other -> other
        end
    end
  end

  defp activation_claimable?(delivery, activation, now, reclaim_after) do
    case activation["status"] do
      status when status in [nil, ""] -> legacy_terminal_summary_pointer?(delivery)
      "pending" -> true
      "failed" -> true
      "activating" -> integer_or_zero(activation["last_attempt_at"]) <= now - reclaim_after
      _ -> false
    end
  end

  defp do_update_delivery_state(_id, _claim, _fun, 0), do: {:error, :lost}

  defp do_update_delivery_state(id, claim, fun, retries) do
    with {:ok, doc, etag} <- get(id),
         state = stringify(doc["state"] || %{}),
         true <- delivery_claim_matches?(state, claim) do
      case cas_put(id, Map.put(doc, "state", stringify(fun.(state))), etag) do
        {:error, :lost} -> do_update_delivery_state(id, claim, fun, retries - 1)
        other -> other
      end
    else
      false -> {:error, :fenced}
      {:error, _} = err -> err
    end
  end

  defp update_activation_state(id, claim, fun, opts \\ []) when is_function(fun, 1) do
    retries = Keyword.get(opts, :retries, 8)

    if valid_activation_claim?(claim) do
      do_update_activation_state(id, stringify(claim), fun, retries)
    else
      {:error, :fenced}
    end
  end

  defp do_update_activation_state(_id, _claim, _fun, 0), do: {:error, :lost}

  defp do_update_activation_state(id, claim, fun, retries) do
    with {:ok, doc, etag} <- get(id),
         state = stringify(doc["state"] || %{}),
         true <- activation_claim_matches?(state, claim, id) do
      case cas_put(id, Map.put(doc, "state", stringify(fun.(state))), etag) do
        {:error, :lost} -> do_update_activation_state(id, claim, fun, retries - 1)
        other -> other
      end
    else
      false -> {:error, :fenced}
      {:error, _} = err -> err
    end
  end

  defp delivery_claim_matches?(state, claim) do
    claim = stringify(claim || %{})
    delivery = stringify(state["delivery"] || %{})

    valid_delivery_claim?(claim) and
      delivery["status"] == "delivering" and
      delivery["published_at"] in [nil, "", false] and
      trim(delivery["claim_node"]) == claim["claim_node"] and
      delivery["attempt_count"] == claim["attempt_count"]
  end

  defp activation_claim_matches?(state, claim, meeting_id) do
    claim = stringify(claim || %{})
    delivery = stringify(state["delivery"] || %{})
    activation = stringify(delivery["activation"] || %{})

    valid_activation_claim?(claim) and activation_delivery_ready?(delivery, meeting_id) and
      activation["status"] == "activating" and
      trim(activation["claim_node"]) == claim["claim_node"] and
      activation["attempt_count"] == claim["attempt_count"]
  end

  defp valid_delivery_claim?(claim) when is_map(claim) do
    claim = stringify(claim)

    trim(claim["claim_node"]) != "" and is_integer(claim["attempt_count"]) and
      claim["attempt_count"] > 0
  end

  defp valid_delivery_claim?(_claim), do: false

  defp valid_activation_claim?(claim) when is_map(claim) do
    claim = stringify(claim)

    trim(claim["claim_node"]) != "" and is_integer(claim["attempt_count"]) and
      claim["attempt_count"] > 0
  end

  defp valid_activation_claim?(_claim), do: false

  defp durable_full_summary_pointer?(delivery, meeting_id) do
    legacy_terminal_summary_pointer?(delivery) or
      FallbackMessageManifest.notes_visible?(delivery, meeting_id)
  end

  defp legacy_terminal_summary_pointer?(delivery) do
    delivery["status"] == "failed_terminal" and
      trim(delivery["summary_message_ts"]) != "" and
      trim(delivery["summary_message_kind"]) in ["", "summary"]
  end

  defp maybe_upgrade_legacy_terminal_notes(state, delivery, now) do
    if legacy_terminal_summary_pointer?(delivery) and
         stringify(delivery["notes_delivery"] || %{})["status"] != "visible" do
      put_delivery(state, %{
        "notes_delivery" => %{
          "status" => "visible",
          "surface" => "canvas_link_message",
          "kind" => "summary",
          "message_ts" => trim(delivery["summary_message_ts"]),
          "visible_at" => div(now, 1_000)
        }
      })
    else
      state
    end
  end

  defp do_claim_join_dispatch(_id, _claim, _opts, 0), do: {:error, :lost}

  defp do_claim_join_dispatch(id, claim, opts, retries) do
    with :ok <- validate_join_claim(claim),
         {:ok, doc, etag} <- get(id) do
      state = stringify(doc["state"] || %{})
      dispatch = stringify(state["join_dispatch"] || %{})
      now = opts[:now] || now_ms()

      cond do
        state["status"] in @terminal_statuses ->
          {:error, :terminal_meeting}

        join_abandoned?(state, dispatch) ->
          {:error, :abandoned}

        dispatch["status"] == "dispatching" and not stale_dispatching?(dispatch, now) ->
          {:error, :join_in_progress}

        dispatch["status"] == "dispatched" and not stale_dispatched?(state, dispatch, now) ->
          {:ok, :dispatched, doc, etag, dispatch}

        # Retry re-claim: a recorded failure or a stale in-doubt claim, with
        # budget left. The caller must satisfy RFC contract one: a
        # definitely-none answer proves it is safe to dispatch again;
        # :idempotent_join attests the runtime-authority face (the pinned
        # runtime dedupes join by meeting_id, so redispatch is safe without a
        # liveness answer); definitely-live converges the record to the truth
        # without a second join; unavailable is fail-closed — this round does
        # not retry and does not consume budget.
        (dispatch["status"] == "failed" or stale_dispatching?(dispatch, now) or
           stale_dispatched?(state, dispatch, now)) and
            join_attempts(dispatch) < @join_max_attempts ->
          # A stale dispatched record (dispatched, never joined, past the reclaim
          # age) that the runtime reports live is still knocking: converging it
          # refreshes the timestamps but is not an attempt, so it must not spend
          # budget — otherwise a human taking ten minutes to admit would
          # exhaust the meeting's retries without a single re-dispatch.
          live_bump = if stale_dispatched?(state, dispatch, now), do: 0, else: 1

          case opts[:liveness] do
            answer when answer in [:none, :idempotent_join] ->
              claimed = %{
                "status" => "dispatching",
                "generation" => claim["generation"],
                "claimed_by" => claim["claimed_by"],
                "claimed_at" => now,
                "completed_at" => nil,
                "last_error" => nil,
                "previous_error" => dispatch["last_error"],
                "attempt_count" => join_attempts(dispatch) + 1
              }

              next_state = Map.put(state, "join_dispatch", claimed)

              case cas_put(id, Map.put(doc, "state", next_state), etag) do
                {:ok, claimed_doc, claimed_etag} ->
                  {:ok, :claimed, claimed_doc, claimed_etag, claimed}

                {:error, :lost} ->
                  do_claim_join_dispatch(id, claim, opts, retries - 1)

                other ->
                  other
              end

            :live ->
              converged = %{
                "status" => "dispatched",
                "generation" => claim["generation"],
                "claimed_by" => claim["claimed_by"],
                "claimed_at" => now,
                "completed_at" => now,
                "last_error" => nil,
                "recovered" => "live_session",
                "attempt_count" => join_attempts(dispatch) + live_bump
              }

              next_state = Map.put(state, "join_dispatch", converged)

              case cas_put(id, Map.put(doc, "state", next_state), etag) do
                {:ok, converged_doc, converged_etag} ->
                  {:ok, :dispatched, converged_doc, converged_etag, converged}

                {:error, :lost} ->
                  do_claim_join_dispatch(id, claim, opts, retries - 1)

                other ->
                  other
              end

            _absent_or_unavailable ->
              {:error, :join_liveness_required}
          end

        dispatch["status"] == "failed" ->
          {:error, {:join_failed, dispatch["last_error"] || "unknown runtime failure"}}

        dispatch["status"] == "dispatching" ->
          {:error, :join_in_progress}

        is_integer(doc["join_requested_at"]) and dispatch == %{} ->
          legacy = %{
            "status" => "dispatched",
            "generation" => "legacy",
            "claimed_by" => "legacy",
            "claimed_at" => doc["join_requested_at"],
            "completed_at" => doc["join_requested_at"],
            "last_error" => nil
          }

          {:ok, :dispatched, doc, etag, legacy}

        dispatch["status"] in [nil, "", "pending"] and is_nil(doc["join_requested_at"]) ->
          claimed = %{
            "status" => "dispatching",
            "generation" => claim["generation"],
            "claimed_by" => claim["claimed_by"],
            "claimed_at" => now,
            "completed_at" => nil,
            "last_error" => nil,
            "attempt_count" => 1
          }

          next_state =
            state
            |> mark_join_requested(now)
            |> Map.put("join_dispatch", claimed)

          next_doc =
            doc
            |> Map.put("join_requested_at", now)
            |> Map.put("state", next_state)

          case cas_put(id, next_doc, etag) do
            {:ok, claimed_doc, claimed_etag} ->
              {:ok, :claimed, claimed_doc, claimed_etag, claimed}

            {:error, :lost} ->
              do_claim_join_dispatch(id, claim, opts, retries - 1)

            other ->
              other
          end

        true ->
          {:error, :join_not_claimable}
      end
    end
  end

  defp do_checkpoint_join_dispatch(_id, _generation, _outcome, _opts, 0),
    do: {:error, :lost}

  defp do_checkpoint_join_dispatch(id, generation, outcome, opts, retries) do
    with {:ok, doc, etag} <- get(id),
         state = stringify(doc["state"] || %{}),
         dispatch = stringify(state["join_dispatch"] || %{}),
         true <-
           dispatch["status"] == "dispatching" and dispatch["generation"] == generation do
      completed_at = opts[:now] || now_ms()

      completed =
        case outcome do
          :dispatched ->
            dispatch
            |> Map.put("status", "dispatched")
            |> Map.put("completed_at", completed_at)
            |> Map.put("last_error", nil)

          {:failed, reason} ->
            dispatch
            |> Map.put("status", "failed")
            |> Map.put("completed_at", completed_at)
            |> Map.put("last_error", inspect(reason))
        end

      next_state =
        state
        |> Map.put("join_dispatch", completed)
        |> maybe_mark_join_failed(outcome)

      case cas_put(id, Map.put(doc, "state", next_state), etag) do
        {:error, :lost} ->
          do_checkpoint_join_dispatch(id, generation, outcome, opts, retries - 1)

        other ->
          other
      end
    else
      false -> {:error, :fenced}
      {:error, _} = error -> error
    end
  end

  defp do_abandon_join_dispatch(_id, _reason, _opts, 0), do: {:error, :lost}

  defp do_abandon_join_dispatch(id, reason, opts, retries) do
    with {:ok, doc, etag} <- get(id) do
      state = stringify(doc["state"] || %{})
      dispatch = stringify(state["join_dispatch"] || %{})

      cond do
        dispatch["status"] in ["dispatching", "dispatched"] ->
          {:error, :join_already_claimed}

        dispatch["status"] == "abandoned" ->
          {:ok, doc, etag}

        is_integer(doc["join_requested_at"]) ->
          {:error, :join_already_claimed}

        true ->
          completed_at = opts[:now] || now_ms()

          abandoned = %{
            "status" => "abandoned",
            "generation" => dispatch["generation"] || "abandoned",
            "claimed_by" => dispatch["claimed_by"],
            "claimed_at" => dispatch["claimed_at"],
            "completed_at" => completed_at,
            "last_error" => inspect(reason)
          }

          next_state =
            state
            |> Map.put("join_dispatch", abandoned)
            |> Map.put("calendar_autojoin_abandoned_at", completed_at)
            |> Map.update(
              "calendar_root",
              %{"status" => "abandoned", "last_error" => inspect(reason)},
              fn root ->
                root
                |> stringify()
                |> Map.put("status", "abandoned")
                |> Map.put("last_error", inspect(reason))
              end
            )

          case cas_put(id, Map.put(doc, "state", next_state), etag) do
            {:error, :lost} -> do_abandon_join_dispatch(id, reason, opts, retries - 1)
            other -> other
          end
      end
    end
  end

  @doc "The join-dispatch attempt budget enforced by the claim CAS."
  def join_max_attempts, do: @join_max_attempts

  @doc "The in-doubt dispatching age after which a join claim is reclaimable."
  def join_reclaim_after_ms, do: @join_reclaim_after_ms

  @doc """
  Whether this meeting's join dispatch is a retry candidate: non-terminal,
  not abandoned, attempts under budget, and either a recorded failure or a
  dispatching claim older than the reclaim window. The claim CAS re-validates
  this predicate — and additionally demands a definite live-session answer —
  before any re-claim.
  """
  def join_retry_candidate?(doc, now \\ nil) do
    now = now || now_ms()
    doc = stringify(doc || %{})
    state = stringify(doc["state"] || %{})
    dispatch = stringify(state["join_dispatch"] || %{})

    state["status"] not in @terminal_statuses and
      not join_abandoned?(state, dispatch) and
      join_attempts(dispatch) < @join_max_attempts and
      (dispatch["status"] == "failed" or stale_dispatching?(dispatch, now) or
         stale_dispatched?(state, dispatch, now))
  end

  # Dispatched, but the runtime never reported a join and the record is older
  # than the reclaim age. This is the "dispatch is not a join" gap: the
  # runtime may still be knocking (the claim's liveness read then converges
  # without a second join), may have died silently, or may have been left at
  # a lobby gate — only the runtime's answer can tell, so this predicate makes
  # the record *eligible* for the gated retry and decides nothing itself.
  defp stale_dispatched?(state, dispatch, now) do
    anchor = dispatch["completed_at"] || dispatch["claimed_at"]

    dispatch["status"] == "dispatched" and is_nil(state["joined_at"]) and
      is_integer(anchor) and anchor <= now - @join_reclaim_after_ms
  end

  defp stale_dispatching?(dispatch, now) do
    dispatch["status"] == "dispatching" and
      is_integer(dispatch["claimed_at"]) and
      dispatch["claimed_at"] <= now - @join_reclaim_after_ms
  end

  # Records written before the retry change carry no attempt_count; any
  # completed status implies exactly one historical attempt.
  @doc false
  def join_attempts(dispatch) do
    case dispatch["attempt_count"] do
      count when is_integer(count) and count > 0 -> count
      _ -> if dispatch["status"] in [nil, "", "pending"], do: 0, else: 1
    end
  end

  defp validate_join_claim(%{"generation" => generation, "claimed_by" => claimed_by}) do
    if trim(generation) != "" and trim(claimed_by) != "",
      do: :ok,
      else: {:error, :invalid_join_claim}
  end

  defp validate_join_claim(_claim), do: {:error, :invalid_join_claim}

  defp join_abandoned?(state, dispatch) do
    dispatch["status"] == "abandoned" or is_integer(state["calendar_autojoin_abandoned_at"]) or
      get_in(state, ["calendar_root", "status"]) == "abandoned"
  end

  defp maybe_mark_join_failed(state, :dispatched), do: state

  defp maybe_mark_join_failed(state, {:failed, reason}) do
    # Meeting-level terminal failure is written only when the attempt budget
    # is exhausted; an in-budget failure stays "joining" and the claim guard
    # makes it reclaimable. If the last claim dies without a checkpoint, the
    # stale-dispatching reclaim (or, past every anchor + cutoff, the summary
    # watchdog) converges it.
    dispatch = stringify(state["join_dispatch"] || %{})

    if join_attempts(dispatch) >= @join_max_attempts do
      state
      |> Map.put("status", "failed")
      |> Map.put("error", inspect(reason))
    else
      state
    end
  end

  defp mark_join_requested(state, at) do
    state = stringify(state)

    status =
      case state["status"] do
        status when status in @terminal_statuses -> status
        _ -> "joining"
      end

    state
    |> Map.put("join_requested_at", at)
    |> Map.put("status", status)
  end

  defp put_delivery(state, attrs) do
    state = stringify(state)
    delivery = Map.merge(state["delivery"] || %{}, stringify(attrs))
    Map.put(state, "delivery", delivery)
  end

  defp put_activation(state, attrs) do
    state = stringify(state)
    delivery = stringify(state["delivery"] || %{})
    activation = Map.merge(stringify(delivery["activation"] || %{}), stringify(attrs))
    Map.put(state, "delivery", Map.put(delivery, "activation", activation))
  end

  defp update_state_retry(_id, _fun, 0), do: {:error, :lost}

  defp update_state_retry(id, fun, retries) do
    with {:ok, _doc, etag} <- get(id) do
      case update_state(id, etag, fun) do
        {:error, :lost} -> update_state_retry(id, fun, retries - 1)
        other -> other
      end
    end
  end

  # Read the live doc only when the held ETag still matches; otherwise the
  # caller's view is stale and any CAS would fail, so surrender early.
  defp read_at(id, etag) do
    case get(id) do
      {:ok, doc, ^etag} -> {:ok, doc, etag}
      {:ok, _doc, _other_etag} -> {:error, :lost}
      other -> other
    end
  end

  defp cas_lead(id, doc, node, etag, now, ttl) do
    doc =
      doc
      |> Map.put("leader_node", node)
      |> Map.put("lease_until", now + ttl)
      |> Map.put("epoch", (doc["epoch"] || 0) + 1)

    cas_put(id, doc, etag)
  end

  defp cas_put(id, doc, etag) do
    case S3.put(Keys.meet_state(id), Jason.encode!(doc), if_match: etag) do
      {:ok, %{etag: new_etag}} -> {:ok, doc, new_etag}
      {:error, :precondition_failed} -> {:error, :lost}
      {:error, {:ambiguous, _}} -> verify(id, doc)
      other -> other
    end
  end

  # Ambiguous CAS: GET-and-check whether our write landed.
  defp verify(id, expected) do
    case get(id) do
      {:ok, doc, etag} ->
        if doc == expected, do: {:ok, doc, etag}, else: {:error, :lost}

      _ ->
        {:error, :lost}
    end
  end

  # Projection-before-state closes the only completeness window for new
  # meetings. A dangling projection is harmless and rebuildable; the bounded
  # reader verifies every row against authoritative state. Crucially, later
  # leadership/state CAS writes do not touch this derived query plane.
  defp ensure_group_projection(%{"id" => meeting_id, "state" => %{"group_id" => group_id}})
       when is_binary(meeting_id) and meeting_id != "" and is_binary(group_id) and group_id != "" do
    case MeetingGroupProjections.ensure(group_id, meeting_id) do
      :ok -> :ok
      {:error, reason} -> {:error, {:meeting_group_projection_unavailable, reason}}
    end
  end

  defp ensure_group_projection(_doc), do: :ok

  defp project_existing(%{"id" => meeting_id, "state" => %{"group_id" => group_id}})
       when is_binary(meeting_id) and meeting_id != "" and is_binary(group_id) and group_id != "" do
    case MeetingGroupProjections.ensure(group_id, meeting_id) do
      :ok -> {:ok, :projected}
      {:error, reason} -> {:error, {:meeting_group_projection_unavailable, reason}}
    end
  end

  defp project_existing(_doc), do: {:ok, :unscoped}

  defp stale?(doc, now), do: is_nil(doc["lease_until"]) or doc["lease_until"] <= now
  defp now_ms, do: System.system_time(:millisecond)
  defp integer_or_zero(value) when is_integer(value), do: value
  defp integer_or_zero(_value), do: 0
  defp maybe_put_continuation_token(opts, nil), do: opts

  defp maybe_put_continuation_token(opts, token),
    do: Keyword.put(opts, :continuation_token, token)

  defp trim(value), do: String.trim(to_string(value || ""))

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value
end
