defmodule SalixStore.S3.Fake do
  @moduledoc """
  In-memory S3 backend with the exact conditional-write semantics of S3, plus
  fault injection for the storage protocol property tests.

  Modeled in tla/salix/S3.tla (its fault vocabulary is the ambiguity
  model the specs use); semantic changes here must move that module.

  A `GenServer` serializes all operations, which gives the same per-object
  linearizable consistency S3 guarantees — the property the whole CAS design
  rests on. ETags are `"<md5hex>"`, matching the real S3 wire format so the
  protocol layer treats both backends identically.

  ## Fault injection

  `set_fault/1` installs a one-shot fault matched against the next operation:

    * `{:ambiguous_after, op, key}` — apply the mutation, then return
      `{:error, {:ambiguous, :injected}}`. This is the dangerous
      "write landed but the response was lost" case; recovery must detect via
      GET-and-check.
    * `{:ambiguous_before, op, key}` — do NOT apply, return ambiguous. The
      "write failed, response lost" case.
    * `{:precondition_after, op, key}` — apply the mutation, then return
      `{:error, {:ambiguous, :conditional_retry_412}}`. This models a real
      adapter retry where attempt 1 landed, its response was lost, and
      attempt 2 got a stale conditional-write 412 — which the AWS adapter
      classifies as AMBIGUOUS (only it knows a retry happened; a clean
      `:precondition_failed` is reserved for first-attempt conflicts that
      provably did not land).
    * `{:apply_after_next_get, :put, key}` — do NOT apply and return
      ambiguous, but keep the write in flight: it lands right AFTER the next
      GET of that key. This is the interleaving a settlement read cannot
      fence — the reader sees the unchanged base, and the original request
      lands before the same-bytes retry, which then takes a stale 412.
      Modeled as the late-apply transition in tla/salix/S3.tla.
    * `{:fail, status, op, key}` — return an HTTP-status error without applying.
    * `{:delay, ms, op, key}` — sleep `ms`, then serve the operation
      normally (a slow request; `op` support: `:get | :put`).
    * `{:pause, op, key}` for `op` in `:get | :put` — park the operation with
      its reply deferred and SERVE OTHER CALLERS meanwhile. A paused GET
      captures the current response and `release_pause/0` delivers it later;
      a paused PUT is applied on release against whatever the object has
      become. Unlike `:delay`, this permits a controlled concurrent mutation.
      Delaying delivery of an already-linearized GET is test synchronization,
      not an additional object-store outcome in `tla/salix/S3.tla`.

  `op` is one of `:put | :get | :delete`; the `:fail` form additionally
  supports `:list` and `:head` (a transient existence-probe failure — the
  #873 round-7 birth-misroute repro). A fault target may be an exact key,
  `:any`, or `{:prefix, prefix}`. Prefix targeting lets concurrent tests fault
  one object family without an unrelated background write consuming the
  one-shot fault. `set_fault_for/2` further limits consumption to operations
  issued directly by one caller process.
  """
  use GenServer
  @behaviour SalixStore.S3

  # ---- lifecycle ----

  def start_link(_ \\ []) do
    case GenServer.start_link(__MODULE__, %{}, name: __MODULE__) do
      {:error, {:already_started, _pid}} ->
        reset()
        :ignore

      other ->
        other
    end
  end

  @doc "Wipe all objects and pending faults (test setup)."
  def reset, do: GenServer.call(__MODULE__, :reset)

  @doc "Install a one-shot fault. See moduledoc."
  def set_fault(spec), do: GenServer.call(__MODULE__, {:set_fault, spec})

  @doc "Install a one-shot fault consumable only by one direct caller process."
  def set_fault_for(owner, spec) when is_pid(owner),
    do: GenServer.call(__MODULE__, {:set_fault_for, owner, spec})

  @doc """
  Install a **persistent** fault (a blackhole): it matches every operation of the
  given kind until `clear_blackhole/0`, modeling a sustained S3 outage for chaos
  tests. Same spec shape as `set_fault/1`.
  """
  def blackhole(spec), do: GenServer.call(__MODULE__, {:blackhole, spec})

  @doc "Remove all persistent faults."
  def clear_blackhole, do: GenServer.call(__MODULE__, :clear_blackhole)

  @doc "Raw object dump for assertions."
  def dump, do: GenServer.call(__MODULE__, :dump)

  @doc "Number of incomplete multipart uploads, for lifecycle assertions."
  def pending_multipart_uploads, do: GenServer.call(__MODULE__, :pending_multipart_uploads)

  @doc """
  Keys of every `put`/`multipart_create` *attempt* since the last reset, oldest
  first — including attempts rejected by preconditions or faults. Lets tests
  assert that a write was (or was not) issued, e.g. that an unchanged
  content-addressed session object is never re-encoded/re-PUT.
  """
  def put_log, do: GenServer.call(__MODULE__, :put_log)

  @doc "True once a `{:pause, :get | :put, key}` fault has parked an operation."
  def paused?, do: GenServer.call(__MODULE__, :paused?)

  @doc "Release the parked operation and reply to its caller."
  def release_pause, do: GenServer.call(__MODULE__, :release_pause)

  @doc "Clear the put log without touching stored objects or faults."
  def reset_put_log, do: GenServer.call(__MODULE__, :reset_put_log)

  @doc "Every GET/HEAD/LIST attempt since the last reset, oldest first."
  def read_log, do: GenServer.call(__MODULE__, :read_log)

  @doc false
  def read_log(owner) when is_pid(owner),
    do: GenServer.call(__MODULE__, {:read_log, owner})

  @doc "Clear the read log without touching stored objects or faults."
  def reset_read_log, do: GenServer.call(__MODULE__, :reset_read_log)

  # ---- behaviour ----

  @impl SalixStore.S3
  def put(key, body, opts),
    do: GenServer.call(__MODULE__, {:put, key, IO.iodata_to_binary(body), opts})

  @impl SalixStore.S3
  def put_stream(key, stream, opts) do
    body = stream |> Enum.into([]) |> IO.iodata_to_binary()
    GenServer.call(__MODULE__, {:put, key, body, opts})
  end

  @impl SalixStore.S3
  def get(key, opts), do: GenServer.call(__MODULE__, {:get, key, opts})

  @impl SalixStore.S3
  def stream(key, opts) do
    case get(key, opts) do
      {:ok, %{body: body}} -> {:ok, chunk_binary(body, 256 * 1024)}
      other -> other
    end
  end

  @impl SalixStore.S3
  def head(key), do: GenServer.call(__MODULE__, {:head, key})

  @impl SalixStore.S3
  def delete(key, opts), do: GenServer.call(__MODULE__, {:delete, key, opts})

  @impl SalixStore.S3
  def list(prefix, opts), do: GenServer.call(__MODULE__, {:list, prefix, opts})

  @impl SalixStore.S3
  def multipart_create(key, opts), do: GenServer.call(__MODULE__, {:multipart_create, key, opts})

  @impl SalixStore.S3
  def multipart_upload_part(key, upload_id, part_number, body),
    do:
      GenServer.call(
        __MODULE__,
        {:multipart_upload_part, key, upload_id, part_number, IO.iodata_to_binary(body)}
      )

  @impl SalixStore.S3
  def multipart_complete(key, upload_id, parts),
    do: GenServer.call(__MODULE__, {:multipart_complete, key, upload_id, parts})

  @impl SalixStore.S3
  def multipart_abort(key, upload_id),
    do: GenServer.call(__MODULE__, {:multipart_abort, key, upload_id})

  @impl SalixStore.S3
  def multipart_uploads(prefix, opts),
    do: GenServer.call(__MODULE__, {:multipart_uploads, prefix, opts})

  # ---- server ----

  @impl GenServer
  def init(_),
    do:
      {:ok,
       %{
         objects: %{},
         uploads: %{},
         faults: [],
         blackholes: [],
         put_log: [],
         read_log: [],
         late_write: nil,
         paused: nil
       }}

  @impl GenServer
  def handle_call(:reset, _from, state) do
    # A parked write holds a caller's `GenServer.call` open. Resetting out
    # from under it would strand that process until its own call timeout —
    # a hang in whichever suite happens to run next, blamed on anything but
    # this. Fail it explicitly instead.
    if state[:paused], do: GenServer.reply(state.paused.from, {:error, :fake_reset})

    {:reply, :ok,
     %{
       objects: %{},
       uploads: %{},
       faults: [],
       blackholes: [],
       put_log: [],
       read_log: [],
       late_write: nil,
       paused: nil
     }}
  end

  def handle_call(:put_log, _from, state),
    do: {:reply, Enum.reverse(state.put_log), state}

  def handle_call(:paused?, _from, state), do: {:reply, state.paused != nil, state}

  def handle_call(:release_pause, _from, %{paused: nil} = state),
    do: {:reply, {:error, :no_paused_write}, state}

  def handle_call(:release_pause, _from, %{paused: %{op: :put} = paused} = state) do
    {:reply, reply, state} =
      apply_put(%{state | paused: nil}, paused.key, paused.body, paused.opts, nil)

    GenServer.reply(paused.from, reply)
    {:reply, :ok, state}
  end

  def handle_call(:release_pause, _from, %{paused: %{op: :get} = paused} = state) do
    GenServer.reply(paused.from, paused.reply)
    {:reply, :ok, %{state | paused: nil}}
  end

  def handle_call(:reset_put_log, _from, state),
    do: {:reply, :ok, %{state | put_log: []}}

  def handle_call(:read_log, _from, state),
    do: {:reply, read_entries(state.read_log), state}

  def handle_call({:read_log, owner}, _from, state),
    do: {:reply, read_entries(state.read_log, owner), state}

  def handle_call(:reset_read_log, _from, state),
    do: {:reply, :ok, %{state | read_log: []}}

  def handle_call({:set_fault, spec}, _from, state),
    do: {:reply, :ok, %{state | faults: state.faults ++ [spec]}}

  def handle_call({:set_fault_for, owner, spec}, _from, state),
    do: {:reply, :ok, %{state | faults: state.faults ++ [{:for_owner, owner, spec}]}}

  def handle_call({:blackhole, spec}, _from, state),
    do: {:reply, :ok, %{state | blackholes: state.blackholes ++ [spec]}}

  def handle_call(:clear_blackhole, _from, state),
    do: {:reply, :ok, %{state | blackholes: []}}

  def handle_call(:dump, _from, state), do: {:reply, state.objects, state}

  def handle_call(:pending_multipart_uploads, _from, state),
    do: {:reply, map_size(state.uploads), state}

  def handle_call({:multipart_uploads, prefix, opts}, _from, state) do
    max_uploads = max(Keyword.get(opts, :max_uploads, 1), 1)

    all =
      state.uploads
      |> Enum.map(fn {upload_id, upload} -> %{key: upload.key, upload_id: upload_id} end)
      |> Enum.filter(&String.starts_with?(&1.key, prefix))
      |> Enum.sort_by(&{&1.key, &1.upload_id})

    page = Enum.take(all, max_uploads)
    next = if length(all) > length(page), do: %{truncated: true}, else: nil
    {:reply, {:ok, %{uploads: page, next: next}}, state}
  end

  def handle_call({:put, key, body, opts}, from, state) do
    state = %{state | put_log: [key | state.put_log]}

    case take_fault(state, :put, key, from) do
      {{:fail, status, _, _}, state} ->
        {:reply, {:error, {:http, status}}, state}

      {{:ambiguous_before, _, _}, state} ->
        {:reply, {:error, {:ambiguous, :injected}}, state}

      # Still in flight: ambiguous now, lands after the next GET of this key.
      {{:apply_after_next_get, _, _}, state} ->
        state = %{state | late_write: %{key: key, body: body, opts: opts}}
        {:reply, {:error, {:ambiguous, :injected}}, state}

      # Parked: the caller waits, the GenServer keeps serving everyone else,
      # and the write is evaluated only when released — against the object
      # as it is THEN, which is what makes a stale precondition observable.
      {{:pause, _, _}, state} ->
        paused = %{op: :put, from: from, key: key, body: body, opts: opts}
        {:noreply, %{state | paused: paused}}

      # Slow write: the request succeeds, late.
      {{:delay, ms, _, _}, state} ->
        Process.sleep(ms)
        apply_put(state, key, body, opts, nil)

      {fault, state} ->
        apply_put(state, key, body, opts, fault)
    end
  end

  def handle_call({:get, key, opts}, from, state) do
    state = log_read(state, from, {:get, key})

    case take_fault(state, :get, key, from) do
      {{:fail, status, _, _}, state} ->
        {:reply, {:error, {:http, status}}, state}

      # Slow read: the response arrives, late. (The GenServer sleeping also
      # serializes the delay, which is fine for cadence tests.)
      {{:delay, ms, _, _}, state} ->
        Process.sleep(ms)
        {:reply, do_get(state, key, opts), state}

      {{:pause, _, _}, state} ->
        reply = do_get(state, key, opts)
        state = land_late_write(state, key)
        {:noreply, %{state | paused: %{op: :get, from: from, reply: reply}}}

      {_, state} ->
        reply = do_get(state, key, opts)
        {:reply, reply, land_late_write(state, key)}
    end
  end

  def handle_call({:head, key}, from, state) do
    state = log_read(state, from, {:head, key})

    case take_fault(state, :head, key, from) do
      {{:fail, status, _, _}, state} ->
        {:reply, {:error, {:http, status}}, state}

      {_, state} ->
        case state.objects[key] do
          nil ->
            {:reply, {:error, :not_found}, state}

          obj ->
            {:reply,
             {:ok,
              %{
                key: key,
                etag: obj.etag,
                size: byte_size(obj.body),
                last_modified: obj.last_modified
              }}, state}
        end
    end
  end

  def handle_call({:delete, key, opts}, from, state) do
    case take_fault(state, :delete, key, from) do
      {{:fail, status, _, _}, state} ->
        {:reply, {:error, {:http, status}}, state}

      {{:ambiguous_before, _, _}, state} ->
        {:reply, {:error, {:ambiguous, :injected}}, state}

      {fault, state} ->
        cur = state.objects[key]

        cond do
          # S3 DELETE is idempotent: unconditional delete of a missing key → 204.
          is_nil(cur) and is_nil(opts[:if_match]) ->
            {:reply, :ok, state}

          # Conditional delete of a missing key: nothing to match → 412.
          is_nil(cur) ->
            {:reply, {:error, :precondition_failed}, state}

          opts[:if_match] && opts[:if_match] != cur.etag ->
            {:reply, {:error, :precondition_failed}, state}

          true ->
            state = update_in(state.objects, &Map.delete(&1, key))

            reply =
              case fault do
                {:ambiguous_after, _, _} -> {:error, {:ambiguous, :injected}}
                {:precondition_after, _, _} -> {:error, {:ambiguous, :conditional_retry_412}}
                _ -> :ok
              end

            {:reply, reply, state}
        end
    end
  end

  def handle_call({:list, prefix, opts}, from, state) do
    state = log_read(state, from, {:list, prefix, opts})

    case take_fault(state, :list, prefix, from) do
      {{:fail, status, _, _}, state} ->
        {:reply, {:error, {:http, status}}, state}

      {_fault, state} ->
        start_after = opts[:start_after]

        all =
          state.objects
          |> Enum.filter(fn {k, _} -> String.starts_with?(k, prefix) end)
          # Some S3-compatible backends apply StartAfter to raw object keys
          # before rolling the remaining keys up into CommonPrefixes. That can
          # re-emit a CommonPrefix equal to StartAfter when it still has child
          # keys. Model that conservative ordering so callers cannot rely on
          # AWS's stronger CommonPrefix filtering.
          |> Enum.filter(fn {key, _object} ->
            is_nil(start_after) or key > start_after
          end)
          |> Enum.map(fn {key, object} -> list_entry(prefix, opts[:delimiter], key, object) end)
          |> Enum.uniq_by(& &1.key)
          |> Enum.sort_by(& &1.key)

        {page, next} = paginate(all, opts)

        objects = for %{type: :object, value: object} <- page, do: object
        common_prefixes = for %{type: :prefix, key: key} <- page, do: key

        {:reply, {:ok, %{objects: objects, common_prefixes: common_prefixes, next: next}}, state}
    end
  end

  def handle_call({:multipart_create, key, opts}, from, state) do
    case take_fault(state, :put, key, from) do
      {{:fail, status, _, _}, state} ->
        {:reply, {:error, {:http, status}}, state}

      {{:ambiguous_before, _, _}, state} ->
        {:reply, {:error, {:ambiguous, :injected}}, state}

      {fault, state} ->
        case check_preconditions(state.objects, key, opts) do
          :ok ->
            upload_id = "fake-upload-" <> random_hex()

            upload = %{
              key: key,
              opts: opts,
              parts: %{},
              fault: fault,
              meta: opts[:meta] || %{}
            }

            {:reply, {:ok, upload_id}, put_in(state.uploads[upload_id], upload)}

          :precondition_failed ->
            {:reply, {:error, :precondition_failed}, state}
        end
    end
  end

  def handle_call({:multipart_upload_part, key, upload_id, part_number, body}, _from, state) do
    case state.uploads[upload_id] do
      %{key: ^key} = upload ->
        etag = etag_for(body)
        part = %{body: body, etag: etag}
        state = put_in(state.uploads[upload_id], put_in(upload.parts[part_number], part))
        {:reply, {:ok, %{etag: etag}}, state}

      _ ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:multipart_complete, key, upload_id, parts}, _from, state) do
    case state.uploads[upload_id] do
      %{key: ^key} = upload ->
        body =
          parts
          |> Enum.map(fn %{part_number: part_number, etag: etag} ->
            case upload.parts[part_number] do
              %{etag: ^etag, body: part_body} -> part_body
              _ -> throw({:bad_part, part_number})
            end
          end)
          |> IO.iodata_to_binary()

        etag = etag_for(body)
        obj = %{body: body, etag: etag, meta: upload.meta, last_modified: now_iso()}

        state =
          state
          |> put_in([:objects, key], obj)
          |> update_in([:uploads], &Map.delete(&1, upload_id))

        reply =
          case upload.fault do
            {:ambiguous_after, _, _} -> {:error, {:ambiguous, :injected}}
            _ -> {:ok, %{etag: etag}}
          end

        {:reply, reply, state}

      _ ->
        {:reply, {:error, :not_found}, state}
    end
  catch
    {:bad_part, part_number} -> {:reply, {:error, {:bad_part, part_number}}, state}
  end

  def handle_call({:multipart_abort, _key, upload_id}, _from, state) do
    {:reply, :ok, update_in(state.uploads, &Map.delete(&1, upload_id))}
  end

  # ---- helpers ----

  defp log_read(state, {owner, _tag}, entry),
    do: %{state | read_log: [{owner, entry} | state.read_log]}

  defp read_entries(read_log),
    do: read_log |> Enum.reverse() |> Enum.map(&elem(&1, 1))

  defp read_entries(read_log, owner) do
    for {^owner, entry} <- Enum.reverse(read_log), do: entry
  end

  defp check_preconditions(objects, key, opts) do
    exists = Map.has_key?(objects, key)
    cur_etag = if exists, do: objects[key].etag

    cond do
      opts[:if_none_match] == "*" and exists -> :precondition_failed
      opts[:if_match] && opts[:if_match] != cur_etag -> :precondition_failed
      true -> :ok
    end
  end

  defp take_fault(state, op, key, {owner, _tag}) do
    case Enum.find_index(state.faults, fn fault ->
           owned_fault_matches?(fault, owner, op, key)
         end) do
      nil ->
        # No one-shot fault; check persistent blackholes (not consumed).
        case Enum.find(state.blackholes, fn f -> fault_matches?(f, op, key) end) do
          nil -> {nil, state}
          bh -> {bh, state}
        end

      idx ->
        fault = state.faults |> Enum.at(idx) |> unwrap_owned_fault()
        {fault, %{state | faults: List.delete_at(state.faults, idx)}}
    end
  end

  defp owned_fault_matches?({:for_owner, owner, fault}, owner, op, key),
    do: fault_matches?(fault, op, key)

  defp owned_fault_matches?({:for_owner, _other_owner, _fault}, _owner, _op, _key), do: false
  defp owned_fault_matches?(fault, _owner, op, key), do: fault_matches?(fault, op, key)

  defp unwrap_owned_fault({:for_owner, _owner, fault}), do: fault
  defp unwrap_owned_fault(fault), do: fault

  # Match the 3-tuple forms ({:ambiguous_after|:ambiguous_before, op, target})
  # and the 4-tuple {:fail, status, op, target} / {:delay, ms, op, target} forms.
  defp fault_matches?({:fail, _status, op, target}, op, key),
    do: fault_target_matches?(target, key)

  defp fault_matches?({:delay, _ms, op, target}, op, key),
    do: fault_target_matches?(target, key)

  defp fault_matches?({_kind, op, target}, op, key), do: fault_target_matches?(target, key)
  defp fault_matches?(_fault, _op, _key), do: false

  defp fault_target_matches?(:any, _key), do: true

  defp fault_target_matches?({:prefix, prefix}, key)
       when is_binary(prefix) and is_binary(key),
       do: String.starts_with?(key, prefix)

  defp fault_target_matches?(key, key), do: true
  defp fault_target_matches?(_target, _key), do: false

  # The in-flight write from `{:apply_after_next_get, ...}` lands here: the
  # reader has already been served the pre-apply value, exactly as when a
  # settlement GET races the original request.
  defp land_late_write(%{late_write: %{key: key} = late} = state, key) do
    case check_preconditions(state.objects, key, late.opts) do
      :ok ->
        etag = etag_for(late.body)

        obj = %{
          body: late.body,
          etag: etag,
          meta: late.opts[:meta] || %{},
          last_modified: now_iso()
        }

        %{state | objects: Map.put(state.objects, key, obj), late_write: nil}

      :precondition_failed ->
        %{state | late_write: nil}
    end
  end

  defp land_late_write(state, _key), do: state

  defp apply_put(state, key, body, opts, fault) do
    case check_preconditions(state.objects, key, opts) do
      :ok ->
        etag = etag_for(body)
        obj = %{body: body, etag: etag, meta: opts[:meta] || %{}, last_modified: now_iso()}
        state = put_in(state.objects[key], obj)

        reply =
          case fault do
            {:ambiguous_after, _, _} -> {:error, {:ambiguous, :injected}}
            {:precondition_after, _, _} -> {:error, {:ambiguous, :conditional_retry_412}}
            _ -> {:ok, %{etag: etag}}
          end

        {:reply, reply, state}

      :precondition_failed ->
        {:reply, {:error, :precondition_failed}, state}
    end
  end

  defp do_get(state, key, opts) do
    case state.objects[key] do
      nil ->
        {:error, :not_found}

      obj ->
        cond do
          opts[:if_none_match] && opts[:if_none_match] == obj.etag ->
            {:error, :not_modified}

          opts[:range] ->
            {start, len} = opts[:range]
            slice = binary_part_safe(obj.body, start, len)
            {:ok, %{body: slice, etag: obj.etag, meta: obj.meta}}

          true ->
            {:ok, %{body: obj.body, etag: obj.etag, meta: obj.meta}}
        end
    end
  end

  defp etag_for(body),
    do: "\"" <> (:crypto.hash(:md5, body) |> Base.encode16(case: :lower)) <> "\""

  defp now_iso, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp random_hex, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

  defp binary_part_safe(bin, start, len) do
    max = byte_size(bin)
    start = min(start, max)
    len = min(len, max - start)
    binary_part(bin, start, len)
  end

  defp chunk_binary(body, chunk_size) do
    Stream.unfold(body, fn
      "" ->
        nil

      rest when byte_size(rest) <= chunk_size ->
        {rest, ""}

      rest ->
        <<chunk::binary-size(^chunk_size), tail::binary>> = rest
        {chunk, tail}
    end)
  end

  defp paginate(objects, opts) do
    max = opts[:max_keys] || 1000

    objects =
      case opts[:continuation_token] do
        nil -> objects
        token -> Enum.drop_while(objects, fn o -> o.key <= decode_continuation_token(token) end)
      end

    if length(objects) > max do
      page = Enum.take(objects, max)
      {page, page |> List.last() |> Map.fetch!(:key) |> encode_continuation_token()}
    else
      {objects, nil}
    end
  end

  defp list_entry(_prefix, nil, key, object) do
    %{
      type: :object,
      key: key,
      value: %{
        key: key,
        etag: object.etag,
        size: byte_size(object.body),
        last_modified: object.last_modified
      }
    }
  end

  defp list_entry(prefix, delimiter, key, object) do
    relative = String.replace_prefix(key, prefix, "")

    case :binary.match(relative, delimiter) do
      {index, length} ->
        common_prefix = prefix <> binary_part(relative, 0, index + length)
        %{type: :prefix, key: common_prefix}

      :nomatch ->
        list_entry(prefix, nil, key, object)
    end
  end

  defp encode_continuation_token(key) do
    "opaque:" <> Base.url_encode64(key, padding: false)
  end

  defp decode_continuation_token("opaque:" <> token) do
    case Base.url_decode64(token, padding: false) do
      {:ok, key} -> key
      :error -> token
    end
  end

  defp decode_continuation_token(token), do: token
end
