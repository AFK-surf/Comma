defmodule SalixStore.S3.AWS do
  @moduledoc """
  Real S3 / MinIO backend over Finch with our own SigV4 signing (path-style).

  Multipart listing stays in this narrow adapter so create/part/complete/abort,
  signing, cross-cloud compatibility, and timeout normalization remain one
  replaceable protocol boundary; introducing a second SDK for one recovery
  operation would split that contract.

  Normalizes S3 HTTP responses into the tagged results defined by
  `SalixStore.S3`:

    * 200/204 → `{:ok, ...}` / `:ok`
    * 304     → `{:error, :not_modified}`
    * 404     → `{:error, :not_found}`
    * 412 on a FIRST attempt → `{:error, :precondition_failed}` — a clean
      conditional write/delete conflict, guaranteed not to be our own write
    * 412 after a transport retry of a CONDITIONAL write/delete →
      `{:error, {:ambiguous, :conditional_retry_412}}` — attempt 1 may have
      landed and be the very version the retry now conflicts with; only
      this adapter knows a retry happened, so the split is made here
    * timeout / 5xx / closed → `{:error, {:ambiguous, reason}}`  (may have landed)

  ## Latency bound (scope: the remote I/O stages)

  The whole-call budget hard-bounds **the remote I/O stages** of a call:
  connection-pool checkout, connect, request-body send, and response
  receive — across every transient retry. Each attempt runs inside a
  cancellable outer deadline set to the remaining budget (see
  `bounded_attempt/7`), and no new attempt or backoff starts once the budget
  is spent, so a stalling or unreachable backend costs a caller the budget,
  not attempts x receive-timeout.

  **Explicitly outside the promise: local CPU work on the payload** —
  traversing or normalizing the caller's own `iodata`, and SigV4 signing
  (which hashes the body). That work is deterministic and proportional to
  the payload the caller already built; it has no stalled/never-terminating
  failure mode, which is what this budget exists to bound (the 2026-08-17
  write stall was 41s of a hung connection with no terminal outcome). As an
  implementation detail the signing hash happens to run inside the
  cancellable attempt task and the budget clock starts at the public entry,
  so local work consumes budget rather than extending the call — but only
  the remote I/O stages are the promised bound, and callers needing an
  absolute limit from their own call site must impose it themselves.

  Per-attempt receive timeouts additionally tier by expected transfer size:
  small operations fail fast, only genuinely large transfers get the long
  window, and each attempt uses `min(tier, remaining budget)`. `stream/2`
  responses are the deliberate exception to the budget: a stream is
  consumer-driven and bounded per read by the bulk receive timeout, so a
  stream that keeps receiving chunks may run past `budget_ms` by design.
  """
  @behaviour SalixStore.S3

  @finch SalixStore.Finch
  @multipart_part_size 5 * 1024 * 1024

  # Per-attempt receive timeouts, tiered by expected transfer size. The store's
  # objects are overwhelmingly small JSON/CAS records (successful-call p99 is
  # tens of milliseconds), so a fast tier bounds how long one bad connection
  # can hold a caller: a stalled attempt fails fast into the transient retry
  # below instead of pinning the caller for the full bulk window. Large bodies
  # (bulk puts at/above @bulk_put_threshold, multipart parts, streams) keep the
  # long window because their transfer time is real.
  #
  # A timeout does NOT weaken the conditional-write contract: it surfaces as an
  # ambiguous outcome exactly like before (the attempt may have landed), and a
  # retried conditional that answers 412 still classifies as
  # `:conditional_retry_412`. Shorter timeouts only make ambiguity arrive
  # sooner; callers' settle-by-read-back obligations are unchanged.
  @fast_recv_timeout 10_000
  @bulk_recv_timeout 30_000
  @bulk_put_threshold 8 * 1024 * 1024

  # Whole-call budget across all transient-retry attempts, hard-bounding the
  # remote I/O stages (see the moduledoc for the exact scope): every attempt
  # runs inside a cancellable outer deadline set to the remaining budget
  # (bounded_attempt/7), and no new attempt or backoff sleep begins once the
  # budget is spent. Worst case for the remote I/O stages is the budget plus
  # milliseconds of scheduling slack, never minutes.
  @request_budget 20_000

  # Finch's default checkout timeout, made explicit. Deliberately NOT clamped
  # to the remaining budget: a checkout timeout surfaces as an exception (not
  # an error tuple), and shrinking this window would turn late-budget attempts
  # into a new crash mode. The outer attempt deadline bounds checkout
  # wall-clock time either way.
  @pool_timeout 5_000

  defp fast_recv_timeout,
    do: Keyword.get(timeouts_config(), :fast_recv_ms, @fast_recv_timeout)

  defp bulk_recv_timeout,
    do: Keyword.get(timeouts_config(), :bulk_recv_ms, @bulk_recv_timeout)

  defp request_budget,
    do: Keyword.get(timeouts_config(), :budget_ms, @request_budget)

  defp timeouts_config, do: Application.get_env(:salix_store, :s3_timeouts, [])

  @impl true
  def put(key, body, opts) do
    # The budget clock starts before the local payload preparation below, so
    # that preparation eats into the budget available to the remote I/O stages
    # rather than extending the call beyond it. The preparation itself is NOT
    # cancellable and is outside the bound by contract (see the moduledoc):
    # the body stays iodata (no eager normalization — signing and Finch both
    # consume iodata), and sizing walks segments without copying bytes.
    deadline = System.monotonic_time(:millisecond) + request_budget()
    cfg = SalixStore.Config.get()

    headers =
      []
      |> atomic_headers(opts, cfg)
      |> maybe([{"content-type", opts[:content_type] || "application/octet-stream"}])
      |> maybe([{"content-length", opts[:content_length]}])
      |> add_meta(opts[:meta], cfg)

    recv_timeout =
      if IO.iodata_length(body) >= @bulk_put_threshold,
        do: bulk_recv_timeout(),
        else: fast_recv_timeout()

    case request("PUT", url(cfg, key), headers, body, cfg, recv_timeout, deadline) do
      {:ok, %{status: status, headers: resp_headers}} when status in 200..204 ->
        {:ok, %{etag: object_token(resp_headers, cfg)}}

      # A 412 on a NON-retried conditional write is a clean conflict: the
      # first attempt's own response says the precondition failed, so this
      # request cannot have landed. A 412 AFTER a transport retry is
      # undecidable — attempt 1 may have landed and attempt 2 hit its own
      # committed state — and only this adapter knows a retry happened, so
      # the distinction is made here: retried conditional 412s surface as
      # ambiguous for the caller's read-back protocol. This is what makes
      # "412 = safe to re-run a CAS reducer" a sound rule upstream.
      {:ok, %{status: 412} = resp} ->
        if Map.get(resp, :retried, false) && conditional_write?(opts) do
          {:error, {:ambiguous, :conditional_retry_412}}
        else
          {:error, :precondition_failed}
        end

      {:ok, %{status: status}} when status in 500..599 ->
        {:error, {:ambiguous, {:http, status}}}

      {:ok, %{status: status, body: rb}} ->
        {:error, {:http, status, rb}}

      {:error, reason} ->
        {:error, {:ambiguous, reason}}
    end
  end

  defp conditional_write?(opts), do: opts[:if_match] != nil or opts[:if_none_match] != nil

  @impl true
  def put_stream(key, stream, opts) do
    case multipart_create(key, opts) do
      {:ok, upload_id} ->
        case upload_stream_parts(key, upload_id, stream) do
          {:ok, []} ->
            _ = multipart_abort(key, upload_id)
            put(key, "", opts)

          {:ok, parts} ->
            multipart_complete(key, upload_id, parts)

          {:error, reason} ->
            _ = multipart_abort(key, upload_id)
            {:error, reason}
        end

      {:error, _} = err ->
        err
    end
  end

  @impl true
  def multipart_create(key, opts) do
    cfg = SalixStore.Config.get()

    headers =
      []
      |> atomic_headers(opts, cfg)
      |> maybe([{"content-type", opts[:content_type] || "application/octet-stream"}])
      |> add_meta(opts[:meta], cfg)

    case request("POST", url(cfg, key) <> "?uploads=", headers, "", cfg) do
      {:ok, %{status: status, body: body}} when status in 200..204 ->
        case tag(body, "UploadId") do
          nil -> {:error, :missing_upload_id}
          upload_id -> {:ok, upload_id}
        end

      {:ok, %{status: 412}} ->
        {:error, :precondition_failed}

      {:ok, %{status: status}} when status in 500..599 ->
        {:error, {:ambiguous, {:http, status}}}

      {:ok, %{status: status, body: rb}} ->
        {:error, {:http, status, rb}}

      {:error, reason} ->
        {:error, {:ambiguous, reason}}
    end
  end

  @impl true
  def multipart_upload_part(key, upload_id, part_number, body)
      when is_binary(body) and part_number >= 1 do
    cfg = SalixStore.Config.get()

    query =
      URI.encode_query([
        {"partNumber", part_number},
        {"uploadId", upload_id}
      ])

    headers = [
      {"content-length", byte_size(body)},
      {"content-type", "application/octet-stream"}
    ]

    case request("PUT", url(cfg, key) <> "?#{query}", headers, body, cfg, bulk_recv_timeout()) do
      {:ok, %{status: status, headers: resp_headers}} when status in 200..204 ->
        {:ok, %{etag: header(resp_headers, "etag") |> normalize_etag()}}

      {:ok, %{status: status}} when status in 500..599 ->
        {:error, {:ambiguous, {:http, status}}}

      {:ok, %{status: status, body: rb}} ->
        {:error, {:http, status, rb}}

      {:error, reason} ->
        {:error, {:ambiguous, reason}}
    end
  end

  @impl true
  def multipart_complete(key, upload_id, parts) do
    cfg = SalixStore.Config.get()
    query = URI.encode_query([{"uploadId", upload_id}])
    body = complete_multipart_xml(parts)

    headers = [
      {"content-length", byte_size(body)},
      {"content-type", "application/xml"}
    ]

    # The server-side assembly after a large multipart upload can itself take
    # seconds, so complete gets the bulk window despite its small XML body.
    case request("POST", url(cfg, key) <> "?#{query}", headers, body, cfg, bulk_recv_timeout()) do
      {:ok, %{status: status, headers: resp_headers}} when status in 200..204 ->
        {:ok, %{etag: object_token(resp_headers, cfg)}}

      {:ok, %{status: status}} when status in 500..599 ->
        {:error, {:ambiguous, {:http, status}}}

      {:ok, %{status: status, body: rb}} ->
        {:error, {:http, status, rb}}

      {:error, reason} ->
        {:error, {:ambiguous, reason}}
    end
  end

  @impl true
  def multipart_abort(key, upload_id) do
    cfg = SalixStore.Config.get()
    query = URI.encode_query([{"uploadId", upload_id}])

    case request("DELETE", url(cfg, key) <> "?#{query}", [], "", cfg) do
      {:ok, %{status: status}} when status in 200..204 -> :ok
      {:ok, %{status: 404}} -> :ok
      {:ok, %{status: status, body: rb}} -> {:error, {:http, status, rb}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def multipart_uploads(prefix, opts) do
    cfg = SalixStore.Config.get()

    query =
      [
        {"uploads", ""},
        {"prefix", prefix}
      ]
      |> maybe_kv("max-uploads", opts[:max_uploads])
      |> maybe_kv("key-marker", opts[:key_marker])
      |> maybe_kv("upload-id-marker", opts[:upload_id_marker])

    full = "#{bucket_url(cfg)}?#{URI.encode_query(query)}"

    case request("GET", full, [], "", cfg) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, parse_multipart_uploads(body)}

      {:ok, %{status: status, body: response_body}} ->
        {:error, {:http, status, response_body}}

      {:error, reason} ->
        {:error, {:ambiguous, reason}}
    end
  end

  @impl true
  def get(key, opts) do
    cfg = SalixStore.Config.get()

    headers =
      []
      |> maybe([{"if-none-match", opts[:if_none_match]}])
      |> range_header(opts[:range])

    case request("GET", url(cfg, key), headers, "", cfg) do
      {:ok, %{status: status, body: body, headers: resp_headers}} when status in [200, 206] ->
        {:ok,
         %{
           body: body,
           etag: object_token(resp_headers, cfg),
           meta: extract_meta(resp_headers)
         }}

      {:ok, %{status: 304}} ->
        {:error, :not_modified}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: status}} when status in 500..599 ->
        {:error, {:ambiguous, {:http, status}}}

      {:ok, %{status: status, body: rb}} ->
        {:error, {:http, status, rb}}

      {:error, reason} ->
        {:error, {:ambiguous, reason}}
    end
  end

  @impl true
  def stream(key, opts) do
    cfg = SalixStore.Config.get()

    headers =
      []
      |> maybe([{"if-none-match", opts[:if_none_match]}])
      |> range_header(opts[:range])

    {:ok, response_stream("GET", url(cfg, key), headers, cfg)}
  end

  @impl true
  def head(key) do
    cfg = SalixStore.Config.get()

    case request("HEAD", url(cfg, key), [], "", cfg) do
      {:ok, %{status: 200, headers: resp_headers}} ->
        {:ok,
         %{
           key: key,
           etag: object_token(resp_headers, cfg),
           size: header(resp_headers, "content-length") |> to_int(),
           last_modified: header(resp_headers, "last-modified")
         }}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, {:ambiguous, reason}}
    end
  end

  @impl true
  def delete(key, opts) do
    cfg = SalixStore.Config.get()

    cond do
      opts[:if_match] && cfg.atomic_operations == :s3 &&
          SalixStore.Config.conditional_delete() == :emulate ->
        emulate_conditional_delete(key, opts[:if_match])

      true ->
        raw_delete(key, opts, cfg)
    end
  end

  # Native delete (optionally with If-Match). S3 DELETE is idempotent: deleting a
  # missing key returns 204 → :ok.
  defp raw_delete(key, opts, cfg \\ SalixStore.Config.get()) do
    headers = atomic_headers([], opts, cfg)

    case request("DELETE", url(cfg, key), headers, "", cfg) do
      {:ok, %{status: status}} when status in [200, 204] ->
        :ok

      {:ok, %{status: 404}} ->
        :ok

      # Same retried-conditional rule as put/3: a 412 after a transport
      # retry may be our own landed delete — ambiguous, not a clean conflict.
      {:ok, %{status: 412} = resp} ->
        if Map.get(resp, :retried, false) && conditional_write?(opts) do
          {:error, {:ambiguous, :conditional_retry_412}}
        else
          {:error, :precondition_failed}
        end

      {:ok, %{status: status}} when status in 500..599 ->
        {:error, {:ambiguous, {:http, status}}}

      {:ok, %{status: status, body: rb}} ->
        {:error, {:http, status, rb}}

      {:error, reason} ->
        {:error, {:ambiguous, reason}}
    end
  end

  # Portable conditional delete for backends that don't enforce If-Match on
  # DELETE: HEAD to read the live ETag; delete only on match.
  # The HEAD→DELETE window is non-atomic: a rewrite landing between the two
  # calls is removed by the unconditional DELETE. Whether that loss gets
  # repaired is the caller's own affair and differs per marker family
  # (participant wakeup markers have no repairing backstop — see the
  # wakeup-marker SSOT in conversation-storage-segmented-target.md; the
  # agent queue-marker family retired with A2 §3.4). Native mode is the
  # only atomic guarantee.
  defp emulate_conditional_delete(key, expected_etag) do
    case head(key) do
      {:ok, %{etag: ^expected_etag}} -> raw_delete(key, [])
      {:ok, %{etag: _other}} -> {:error, :precondition_failed}
      {:error, :not_found} -> {:error, :precondition_failed}
      {:error, reason} -> {:error, {:ambiguous, reason}}
    end
  end

  @impl true
  def list(prefix, opts) do
    cfg = SalixStore.Config.get()

    query =
      [
        {"list-type", "2"},
        {"prefix", prefix}
      ]
      |> maybe_kv("max-keys", opts[:max_keys])
      |> maybe_kv("continuation-token", opts[:continuation_token])
      |> maybe_kv("delimiter", opts[:delimiter])
      |> maybe_kv("start-after", opts[:start_after])

    qs = URI.encode_query(query)
    full = "#{bucket_url(cfg)}?#{qs}"

    case request("GET", full, [], "", cfg) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, parse_list(body)}

      {:ok, %{status: status, body: rb}} ->
        {:error, {:http, status, rb}}

      {:error, reason} ->
        {:error, {:ambiguous, reason}}
    end
  end

  # ---- HTTP plumbing ----

  @transient_retries 3

  # `deadline` defaults to budget-from-now, which is exact for every operation
  # whose entry does no payload work; `put/3` passes its own, started at the
  # public boundary before body sizing.
  defp request(method, url, headers, body, cfg, recv_timeout \\ nil, deadline \\ nil) do
    recv_timeout = recv_timeout || fast_recv_timeout()
    deadline = deadline || System.monotonic_time(:millisecond) + request_budget()
    do_request(method, url, headers, body, cfg, recv_timeout, deadline, @transient_retries)
  end

  defp response_stream(method, url, headers, cfg) do
    Stream.resource(
      fn ->
        parent = self()
        ref = make_ref()

        task =
          Task.async(fn ->
            signed = SalixStore.SigV4.sign(method, url, headers, "", cfg)

            result =
              Finch.build(method_atom(method), url, signed, "")
              |> Finch.stream(
                @finch,
                nil,
                fn event, acc ->
                  send(parent, {ref, event})
                  acc
                end,
                receive_timeout: bulk_recv_timeout()
              )

            send(parent, {ref, :done, result})
          end)

        %{ref: ref, task: task}
      end,
      &next_stream_chunk/1,
      fn %{task: task} -> Task.shutdown(task, :brutal_kill) end
    )
  end

  defp next_stream_chunk(%{ref: ref} = state) do
    receive do
      {^ref, {:status, status}} when status in [200, 206] ->
        next_stream_chunk(state)

      {^ref, {:status, 304}} ->
        raise "s3 stream read failed: :not_modified"

      {^ref, {:status, 404}} ->
        raise "s3 stream read failed: :not_found"

      {^ref, {:status, status}} ->
        raise "s3 stream read failed: http #{status}"

      {^ref, {:headers, _headers}} ->
        next_stream_chunk(state)

      {^ref, {:data, data}} ->
        {[data], state}

      {^ref, {:trailers, _trailers}} ->
        next_stream_chunk(state)

      {^ref, :done, {:ok, _acc}} ->
        {:halt, state}

      {^ref, :done, {:error, reason, _acc}} ->
        raise "s3 stream read failed: #{inspect(reason)}"
    end
  end

  # Retry transient transport errors (stale pooled connection closed by the
  # server, connect timeouts). Responses are stamped with whether a retry
  # happened: a conditional mutation retried after a genuinely-landed first
  # attempt can resolve to 412, and the operation callers (put/delete)
  # translate that retried-conditional 412 into an ambiguous outcome — only
  # this layer knows the retry history, and collapsing it into a clean
  # conflict would let CAS callers re-run reducers over their own committed
  # writes.
  #
  # The deadline is threaded through every attempt: the remaining budget is
  # each attempt's complete-response limit (Finch `:request_timeout`) and
  # clamps its receive timeout, and both the retry decision and the backoff
  # sleep re-check it. A spent budget surfaces the plain `:timeout` transport
  # error — an ambiguous outcome upstream, same as any other timeout, so the
  # settle-by-read-back obligation is unchanged.
  defp do_request(method, url, headers, body, cfg, recv_timeout, deadline, attempts_left) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, %Mint.TransportError{reason: :timeout}}
    else
      result = bounded_attempt(method, url, headers, body, cfg, recv_timeout, deadline)

      case result do
        {:error, %{__struct__: struct, reason: reason}}
        when struct in [Finch.TransportError, Mint.TransportError] and
               reason in [:closed, :timeout, :econnrefused] and attempts_left > 0 ->
          backoff = transient_backoff(attempts_left)

          if System.monotonic_time(:millisecond) + backoff < deadline do
            Process.sleep(backoff)
            do_request(method, url, headers, body, cfg, recv_timeout, deadline, attempts_left - 1)
          else
            result
          end

        {:ok, resp} ->
          {:ok, Map.put(resp, :retried, attempts_left < @transient_retries)}

        other ->
          other
      end
    end
  end

  # One attempt under ONE cancellable wall-clock bound covering payload
  # signing, pool checkout, connect, request-body send, and response receive.
  # The inner Finch timeouts alone cannot provide this: `request_timeout`
  # starts counting only after the request body has been sent (a wedged
  # upload never reaches it) and pool checkout precedes it entirely — and
  # SigV4 signing hashes the ENTIRE body, so for a large payload the hash
  # alone can dwarf the budget; it therefore runs inside the task, and the
  # network phase recomputes its remainder from the ABSOLUTE deadline after
  # signing (a pre-signing remainder would be stale by the whole hash time).
  # On expiry the task is brutally killed; Finch monitors the checked-out
  # caller and discards its connection on caller death, so a wedged socket is
  # retired, never returned to the pool. The kill surfaces the plain
  # `:timeout` transport error — ambiguous upstream (the request may have
  # landed), preserving the callers' settle-by-read-back obligation.
  # Exceptions raised inside the attempt are re-raised in the caller with
  # their original stacktrace, and an abnormal task exit propagates, matching
  # the previous un-wrapped behaviour.
  defp bounded_attempt(method, url, headers, body, cfg, recv_timeout, deadline) do
    task =
      Task.async(fn ->
        try do
          signed = SalixStore.SigV4.sign(method, url, headers, body, cfg)
          remaining = max(deadline - System.monotonic_time(:millisecond), 1)

          {:finch,
           Finch.build(method_atom(method), url, signed, body)
           |> Finch.request(@finch,
             receive_timeout: min(recv_timeout, remaining),
             request_timeout: remaining,
             pool_timeout: @pool_timeout
           )}
        rescue
          exception -> {:raised, exception, __STACKTRACE__}
        end
      end)

    case Task.yield(task, max(deadline - System.monotonic_time(:millisecond), 0)) ||
           Task.shutdown(task, :brutal_kill) do
      {:ok, {:finch, result}} -> result
      {:ok, {:raised, exception, stacktrace}} -> reraise(exception, stacktrace)
      {:exit, reason} -> exit(reason)
      nil -> {:error, %Mint.TransportError{reason: :timeout}}
    end
  end

  defp transient_backoff(attempts_left) do
    # 3→10ms, 2→20ms, 1→40ms (jitter-free; contention here is rare)
    case attempts_left do
      3 -> 10
      2 -> 20
      _ -> 40
    end
  end

  defp method_atom("GET"), do: :get
  defp method_atom("PUT"), do: :put
  defp method_atom("HEAD"), do: :head
  defp method_atom("DELETE"), do: :delete
  defp method_atom("POST"), do: :post

  defp url(cfg, key) do
    "#{bucket_url(cfg)}/#{encode_key(key)}"
  end

  defp bucket_url(cfg) do
    # path-style addressing (MinIO + dev). endpoint already includes scheme+host.
    "#{String.trim_trailing(cfg.endpoint, "/")}/#{cfg.bucket}"
  end

  # Encode key segments but keep slashes as path separators.
  defp encode_key(key) do
    key
    |> String.split("/")
    |> Enum.map(fn seg -> URI.encode(seg, &uri_unreserved?/1) end)
    |> Enum.join("/")
  end

  defp uri_unreserved?(c) do
    c in ?A..?Z or c in ?a..?z or c in ?0..?9 or c in [?-, ?_, ?., ?~]
  end

  defp atomic_headers(headers, opts, %{atomic_operations: :gcp}) do
    cond do
      opts[:if_match] ->
        maybe(headers, [{"x-goog-if-generation-match", opts[:if_match]}])

      opts[:if_none_match] == "*" ->
        maybe(headers, [{"x-goog-if-generation-match", "0"}])

      true ->
        headers
    end
  end

  defp atomic_headers(headers, opts, _cfg) do
    headers
    |> maybe([{"if-none-match", opts[:if_none_match]}])
    |> maybe([{"if-match", opts[:if_match]}])
  end

  defp maybe(headers, [{_k, nil}]), do: headers
  defp maybe(headers, [{k, v}]), do: headers ++ [{k, to_string(v)}]

  defp maybe_kv(query, _k, nil), do: query
  defp maybe_kv(query, k, v), do: query ++ [{k, to_string(v)}]

  defp range_header(headers, nil), do: headers

  defp range_header(headers, {start, len}) do
    last = start + len - 1
    headers ++ [{"range", "bytes=#{start}-#{last}"}]
  end

  defp add_meta(headers, nil, _cfg), do: headers
  defp add_meta(headers, %{} = meta, _cfg) when map_size(meta) == 0, do: headers

  defp add_meta(headers, meta, %{atomic_operations: :gcp}) do
    headers ++ Enum.map(meta, fn {k, v} -> {"x-goog-meta-#{k}", to_string(v)} end)
  end

  defp add_meta(headers, meta, _cfg) do
    headers ++ Enum.map(meta, fn {k, v} -> {"x-amz-meta-#{k}", to_string(v)} end)
  end

  defp extract_meta(resp_headers) do
    resp_headers
    |> Enum.filter(fn {k, _} ->
      k = String.downcase(k)
      String.starts_with?(k, "x-amz-meta-") or String.starts_with?(k, "x-goog-meta-")
    end)
    |> Map.new(fn {k, v} ->
      key =
        k
        |> String.downcase()
        |> String.replace_prefix("x-amz-meta-", "")
        |> String.replace_prefix("x-goog-meta-", "")

      {key, v}
    end)
  end

  defp header(headers, name) do
    name = String.downcase(name)

    Enum.find_value(headers, fn {k, v} ->
      if String.downcase(k) == name, do: v
    end)
  end

  defp object_token(headers, %{atomic_operations: :gcp}) do
    header(headers, "x-goog-generation") || header(headers, "etag") |> normalize_etag()
  end

  defp object_token(headers, _cfg), do: header(headers, "etag") |> normalize_etag()

  defp normalize_etag(nil), do: nil
  defp normalize_etag(etag), do: etag

  defp upload_stream_parts(key, upload_id, stream) do
    state = %{buffer: "", part_number: 1, parts: []}

    stream
    |> Enum.reduce_while({:ok, state}, fn chunk, {:ok, state} ->
      chunk = IO.iodata_to_binary(chunk)
      state = %{state | buffer: state.buffer <> chunk}

      case upload_full_parts(key, upload_id, state) do
        {:ok, state} -> {:cont, {:ok, state}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, state} -> upload_final_part(key, upload_id, state)
      {:error, _} = err -> err
    end
  rescue
    e -> {:error, e}
  end

  defp upload_full_parts(key, upload_id, state) do
    if byte_size(state.buffer) >= @multipart_part_size do
      <<part::binary-size(@multipart_part_size), rest::binary>> = state.buffer

      with {:ok, %{etag: etag}} <-
             multipart_upload_part(key, upload_id, state.part_number, part) do
        upload_full_parts(key, upload_id, %{
          state
          | buffer: rest,
            part_number: state.part_number + 1,
            parts: [%{part_number: state.part_number, etag: etag} | state.parts]
        })
      end
    else
      {:ok, state}
    end
  end

  defp upload_final_part(_key, _upload_id, %{buffer: "", parts: []}), do: {:ok, []}

  defp upload_final_part(key, upload_id, %{buffer: buffer} = state) do
    if buffer == "" do
      {:ok, Enum.reverse(state.parts)}
    else
      with {:ok, %{etag: etag}} <-
             multipart_upload_part(key, upload_id, state.part_number, buffer) do
        {:ok, Enum.reverse([%{part_number: state.part_number, etag: etag} | state.parts])}
      end
    end
  end

  defp complete_multipart_xml(parts) do
    inner =
      parts
      |> Enum.map(fn %{part_number: part_number, etag: etag} ->
        "<Part><PartNumber>#{part_number}</PartNumber><ETag>#{xml_escape(etag)}</ETag></Part>"
      end)
      |> Enum.join()

    "<?xml version=\"1.0\" encoding=\"UTF-8\"?><CompleteMultipartUpload>#{inner}</CompleteMultipartUpload>"
  end

  defp xml_escape(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp to_int(nil), do: nil
  defp to_int(s) when is_binary(s), do: String.to_integer(s)

  # Minimal XML parse of ListBucketResult — avoids an XML dep for the few
  # fields we need. S3/MinIO emit predictable, un-nested element shapes here.
  defp parse_list(xml) do
    objects =
      Regex.scan(~r{<Contents>(.*?)</Contents>}s, xml)
      |> Enum.map(fn [_, inner] ->
        %{
          key: tag(inner, "Key"),
          etag: tag(inner, "ETag") |> normalize_etag(),
          size: (tag(inner, "Size") || "0") |> String.to_integer(),
          last_modified: tag(inner, "LastModified")
        }
      end)

    common_prefixes =
      Regex.scan(~r{<CommonPrefixes>(.*?)</CommonPrefixes>}s, xml)
      |> Enum.flat_map(fn [_, inner] ->
        case tag(inner, "Prefix") do
          nil -> []
          prefix -> [prefix]
        end
      end)

    next =
      case tag(xml, "NextContinuationToken") do
        nil -> nil
        "" -> nil
        token -> unescape(token)
      end

    %{objects: objects, common_prefixes: common_prefixes, next: next}
  end

  defp parse_multipart_uploads(xml) do
    uploads =
      Regex.scan(~r{<Upload>(.*?)</Upload>}s, xml)
      |> Enum.map(fn [_, inner] ->
        %{key: tag(inner, "Key"), upload_id: tag(inner, "UploadId")}
      end)
      |> Enum.filter(&(is_binary(&1.key) and is_binary(&1.upload_id)))

    next =
      if tag(xml, "IsTruncated") == "true" do
        %{
          key_marker: tag(xml, "NextKeyMarker"),
          upload_id_marker: tag(xml, "NextUploadIdMarker")
        }
      end

    %{uploads: uploads, next: next}
  end

  defp tag(xml, name) do
    case Regex.run(~r{<#{name}>(.*?)</#{name}>}s, xml) do
      [_, val] -> unescape(val)
      _ -> nil
    end
  end

  defp unescape(s) do
    s
    |> String.replace("&#34;", "\"")
    |> String.replace("&#x22;", "\"")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&#x27;", "'")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&amp;", "&")
  end
end
