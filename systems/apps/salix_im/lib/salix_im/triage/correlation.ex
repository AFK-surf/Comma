defmodule SalixIM.Triage.Correlation do
  @moduledoc """
  Private operator correlation index for authoritative Triage runs.

  Raw provider identifiers are reduced to canonical selector hashes before
  they cross the RunFence authorization boundary. The durable index is a
  derived pointer only: this module never answers from the index alone, and
  every lookup re-reads the run through `Ledger.fetch/2`.

  What that re-read proves is exactly what `Ledger.fetch/2` proves and no more:
  the run record and its replay record agree on `run_sha256`, so a run edited on
  its own is refused. It is NOT a chain — runs are not linked to each other,
  there is no head or anchor, and a writer who rewrites the run and its replay
  record together produces a pair every consumer accepts. Following a stale or
  forged index entry therefore cannot surface a half-rewritten run, but it can
  surface a coherently rewritten one. See `SalixIM.Triage.Ledger`'s "Threat
  model" section.
  """

  alias SalixIM.Triage.{CanonicalJSON, Ledger}
  alias SalixStore.{CasRecord, ULID}

  @binding_schema "comma.triage-run-correlation-binding.v1"
  @entry_schema "comma.triage-run-correlation-index-entry.v1"
  @result_schema "comma.triage-admin-run-lookup.v1"
  @time_entry_schema "comma.triage-run-time-index-entry.v1"
  @window_schema "comma.triage-admin-run-window.v1"
  @selector_kinds ~w(receipt_ref slack_event_id slack_message)
  @max_created_at 9_999_999_999_999
  @max_window_limit 50

  @doc "Builds token-free correlation bindings from an exact winning input."
  @spec bindings(map()) :: {:ok, [map()]} | {:error, :invalid_triage_correlation}
  def bindings(%{
        "schema" => "comma.triage-input-snapshot.v2",
        "events" => [_ | _] = events,
        "receipt_refs" => [_ | _] = receipt_refs
      }) do
    with true <- is_list(receipt_refs),
         true <- length(events) == length(receipt_refs) do
      bindings =
        events
        |> Enum.zip(receipt_refs)
        |> Enum.flat_map(fn {event, receipt_ref} ->
          [event_binding(event), receipt_binding(receipt_ref), slack_message_binding(event)]
        end)
        |> Enum.uniq()

      if Enum.all?(bindings, &valid_binding?/1),
        do: {:ok, bindings},
        else: {:error, :invalid_triage_correlation}
    else
      _invalid -> {:error, :invalid_triage_correlation}
    end
  end

  def bindings(_winning_input), do: {:error, :invalid_triage_correlation}

  @doc "Persists create-once derived pointers for one already-public run."
  @spec persist(String.t(), [map()], map()) :: :ok | {:error, term()}
  def persist(namespace, bindings, run)
      when is_binary(namespace) and namespace != "" and is_list(bindings) and is_map(run) do
    with true <- ULID.valid?(run["run_id"]),
         true <- run["authoritative"] == true,
         true <- Enum.all?(bindings, &valid_binding?/1) do
      with :ok <- persist_bindings(namespace, bindings, run),
           :ok <- persist_time_entry(namespace, run) do
        :ok
      end
    else
      _invalid -> {:error, :invalid_triage_correlation}
    end
  end

  def persist(_namespace, _bindings, _run), do: {:error, :invalid_triage_correlation}

  @doc "Looks up one safe authoritative run by an exact operator selector."
  @spec lookup(
          String.t(),
          {:slack_event_id, String.t()}
          | {:receipt_ref, String.t()}
          | {:slack_permalink, String.t()}
        ) ::
          {:ok, map()} | {:error, :not_found | :ambiguous | :invalid_triage_correlation | term()}
  def lookup(namespace, selector) when is_binary(namespace) and namespace != "" do
    with {:ok, binding} <- binding_for_selector(selector),
         prefix =
           SalixStore.TriageKeys.ctl_im_triage_run_correlations_prefix(
             namespace,
             binding["selector_kind"],
             binding["selector_sha256"]
           ),
         {:ok, %{objects: objects}} <- SalixStore.TriageRecordStore.list(prefix, max_keys: 2),
         {:ok, object} <- one_object(objects),
         {:ok, entry} <- CasRecord.get(object.key),
         true <- valid_entry?(namespace, binding, object.key, entry),
         {:ok, run} <- Ledger.fetch(namespace, entry["run_id"]),
         true <- sha256(run) == entry["run_sha256"] do
      {:ok,
       %{
         "schema" => @result_schema,
         "selector_kind" => binding["selector_kind"],
         "run_id" => entry["run_id"],
         "run" => run
       }}
    else
      {:error, :not_found} -> {:error, :not_found}
      {:error, :ambiguous} -> {:error, :ambiguous}
      {:error, :invalid_triage_correlation} = error -> error
      false -> {:error, :invalid_triage_correlation}
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_triage_correlation}
    end
  end

  def lookup(_namespace, _selector), do: {:error, :invalid_triage_correlation}

  @doc "Returns one bounded, chronological window of safe authoritative runs."
  @spec lookup_window(String.t(), {:created_between, integer(), integer()}, keyword()) ::
          {:ok, map()} | {:error, :invalid_triage_correlation | term()}
  def lookup_window(namespace, {:created_between, from_ms, to_ms}, opts)
      when is_binary(namespace) and namespace != "" and is_integer(from_ms) and
             is_integer(to_ms) and is_list(opts) do
    limit = Keyword.get(opts, :limit, 20)

    with true <- Keyword.keys(opts) -- [:limit] == [],
         true <- from_ms >= 0 and from_ms <= to_ms and to_ms <= @max_created_at,
         true <- is_integer(limit) and limit > 0 and limit <= @max_window_limit,
         prefix = SalixStore.TriageKeys.ctl_im_triage_run_time_index_prefix(namespace),
         start_after = prefix <> padded_created_at(from_ms),
         {:ok, %{objects: objects}} <-
           SalixStore.TriageRecordStore.list(prefix,
             start_after: start_after,
             max_keys: limit + 1
           ),
         {:ok, entries} <- read_time_entries(namespace, objects),
         in_window = Enum.take_while(entries, &(&1["created_at"] <= to_ms)),
         truncated = length(in_window) > limit,
         selected = Enum.take(in_window, limit),
         {:ok, runs} <- fetch_time_runs(namespace, selected) do
      {:ok,
       %{
         "schema" => @window_schema,
         "from_ms" => from_ms,
         "to_ms" => to_ms,
         "limit" => limit,
         "truncated" => truncated,
         "runs" => runs
       }}
    else
      false -> {:error, :invalid_triage_correlation}
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_triage_correlation}
    end
  end

  def lookup_window(_namespace, _range, _opts), do: {:error, :invalid_triage_correlation}

  defp persist_bindings(namespace, bindings, run) do
    Enum.reduce_while(bindings, :ok, fn binding, :ok ->
      entry = %{
        "schema" => @entry_schema,
        "selector_kind" => binding["selector_kind"],
        "selector_sha256" => binding["selector_sha256"],
        "run_id" => run["run_id"],
        "run_sha256" => sha256(run),
        "created_at" => run["created_at"]
      }

      key =
        SalixStore.TriageKeys.ctl_im_triage_run_correlation(
          namespace,
          binding["selector_kind"],
          binding["selector_sha256"],
          run["run_id"]
        )

      case create_or_same(key, entry) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp persist_time_entry(namespace, run) do
    entry = %{
      "schema" => @time_entry_schema,
      "run_id" => run["run_id"],
      "run_sha256" => sha256(run),
      "created_at" => run["created_at"]
    }

    if valid_time_entry?(
         namespace,
         SalixStore.TriageKeys.ctl_im_triage_run_time_index_entry(
           namespace,
           run["created_at"],
           run["run_id"]
         ),
         entry
       ) do
      create_or_same(
        SalixStore.TriageKeys.ctl_im_triage_run_time_index_entry(
          namespace,
          run["created_at"],
          run["run_id"]
        ),
        entry
      )
    else
      {:error, :invalid_triage_correlation}
    end
  end

  defp read_time_entries(namespace, objects) do
    Enum.reduce_while(objects, {:ok, []}, fn %{key: key}, {:ok, entries} ->
      case CasRecord.get(key) do
        {:ok, entry} ->
          if valid_time_entry?(namespace, key, entry),
            do: {:cont, {:ok, [entry | entries]}},
            else: {:halt, {:error, :invalid_triage_correlation}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end

  defp fetch_time_runs(namespace, entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, runs} ->
      case Ledger.fetch(namespace, entry["run_id"]) do
        {:ok, run} ->
          if sha256(run) == entry["run_sha256"] and run["created_at"] == entry["created_at"],
            do: {:cont, {:ok, [run | runs]}},
            else: {:halt, {:error, :invalid_triage_correlation}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, runs} -> {:ok, Enum.reverse(runs)}
      error -> error
    end
  end

  defp event_binding(%{"event_id" => event_id}) when is_binary(event_id) do
    event_id = String.trim(event_id)

    if event_id == "",
      do: %{},
      else: selector_binding("slack_event_id", %{"event_id" => event_id})
  end

  defp event_binding(_event), do: %{}

  defp receipt_binding(receipt_ref) when is_binary(receipt_ref) do
    receipt_ref = String.trim(receipt_ref)

    if receipt_ref == "",
      do: %{},
      else: selector_binding("receipt_ref", %{"receipt_ref" => receipt_ref})
  end

  defp receipt_binding(_receipt_ref), do: %{}

  defp slack_message_binding(%{
         "message_ts" => message_ts,
         "bucket" => %{"channel_id" => channel_id}
       }) do
    with {:ok, message_ts} <- normalize_message_ts(message_ts),
         true <- nonempty?(channel_id) do
      selector_binding("slack_message", %{
        "channel_id" => String.trim(channel_id),
        "message_ts" => message_ts
      })
    else
      _invalid -> %{}
    end
  end

  defp slack_message_binding(_event), do: %{}

  defp binding_for_selector({:slack_event_id, event_id}) when is_binary(event_id) do
    binding = event_binding(%{"event_id" => event_id})

    if valid_binding?(binding),
      do: {:ok, binding},
      else: {:error, :invalid_triage_correlation}
  end

  defp binding_for_selector({:receipt_ref, receipt_ref}) when is_binary(receipt_ref) do
    binding = receipt_binding(receipt_ref)

    if valid_binding?(binding),
      do: {:ok, binding},
      else: {:error, :invalid_triage_correlation}
  end

  defp binding_for_selector({:slack_permalink, permalink}) when is_binary(permalink) do
    with {:ok, channel_id, message_ts} <- parse_slack_permalink(permalink) do
      binding =
        selector_binding("slack_message", %{
          "channel_id" => channel_id,
          "message_ts" => message_ts
        })

      if valid_binding?(binding),
        do: {:ok, binding},
        else: {:error, :invalid_triage_correlation}
    end
  end

  defp binding_for_selector(_selector), do: {:error, :invalid_triage_correlation}

  defp selector_binding(kind, fields) do
    selector =
      Map.merge(%{"schema" => "comma.triage-run-correlation-selector.v1", "kind" => kind}, fields)

    %{
      "schema" => @binding_schema,
      "selector_kind" => kind,
      "selector_sha256" => selector |> CanonicalJSON.encode!() |> CanonicalJSON.sha256()
    }
  end

  defp parse_slack_permalink(permalink) do
    with {:ok, url} <- unwrap_slack_link(String.trim(permalink)),
         %URI{scheme: "https", host: host, path: path} <- URI.parse(url),
         true <- is_binary(host) and String.ends_with?(String.downcase(host), ".slack.com"),
         ["archives", channel_id, "p" <> compact_ts] <-
           path |> String.trim_leading("/") |> String.split("/"),
         true <- nonempty?(channel_id),
         true <- Regex.match?(~r/\A[0-9]+\z/, compact_ts),
         true <- byte_size(compact_ts) > 6,
         {seconds, microseconds} <- String.split_at(compact_ts, byte_size(compact_ts) - 6),
         {:ok, message_ts} <- normalize_message_ts(seconds <> "." <> microseconds) do
      {:ok, channel_id, message_ts}
    else
      _invalid -> {:error, :invalid_triage_correlation}
    end
  end

  defp unwrap_slack_link("<" <> wrapped) do
    case String.split(String.trim_trailing(wrapped, ">"), "|", parts: 2) do
      [url] -> {:ok, url}
      [url, _label] -> {:ok, url}
    end
  end

  defp unwrap_slack_link(url) when url != "", do: {:ok, url}
  defp unwrap_slack_link(_url), do: {:error, :invalid_triage_correlation}

  defp normalize_message_ts(value) when is_binary(value) do
    case String.split(String.trim(value), ".", parts: 2) do
      [seconds, fraction]
      when byte_size(seconds) > 0 and byte_size(fraction) > 0 and byte_size(fraction) <= 6 ->
        if Regex.match?(~r/\A[0-9]+\z/, seconds) and Regex.match?(~r/\A[0-9]+\z/, fraction) do
          {:ok,
           Integer.to_string(String.to_integer(seconds)) <>
             "." <>
             String.pad_trailing(fraction, 6, "0")}
        else
          {:error, :invalid_triage_correlation}
        end

      _invalid ->
        {:error, :invalid_triage_correlation}
    end
  end

  defp normalize_message_ts(_value), do: {:error, :invalid_triage_correlation}

  defp valid_binding?(binding) do
    exact_map_keys?(binding, ~w(schema selector_kind selector_sha256)) and
      binding["schema"] == @binding_schema and binding["selector_kind"] in @selector_kinds and
      valid_sha256?(binding["selector_sha256"])
  end

  defp valid_entry?(namespace, binding, key, entry) do
    exact_map_keys?(
      entry,
      ~w(schema selector_kind selector_sha256 run_id run_sha256 created_at)
    ) and entry["schema"] == @entry_schema and
      entry["selector_kind"] == binding["selector_kind"] and
      entry["selector_sha256"] == binding["selector_sha256"] and
      ULID.valid?(entry["run_id"]) and valid_sha256?(entry["run_sha256"]) and
      is_integer(entry["created_at"]) and entry["created_at"] > 0 and
      key ==
        SalixStore.TriageKeys.ctl_im_triage_run_correlation(
          namespace,
          entry["selector_kind"],
          entry["selector_sha256"],
          entry["run_id"]
        )
  end

  defp valid_time_entry?(namespace, key, entry) do
    exact_map_keys?(entry, ~w(schema run_id run_sha256 created_at)) and
      entry["schema"] == @time_entry_schema and ULID.valid?(entry["run_id"]) and
      valid_sha256?(entry["run_sha256"]) and is_integer(entry["created_at"]) and
      entry["created_at"] > 0 and entry["created_at"] <= @max_created_at and
      key ==
        SalixStore.TriageKeys.ctl_im_triage_run_time_index_entry(
          namespace,
          entry["created_at"],
          entry["run_id"]
        )
  end

  defp one_object([]), do: {:error, :not_found}
  defp one_object([object]), do: {:ok, object}
  defp one_object([_first, _second | _rest]), do: {:error, :ambiguous}

  defp create_or_same(key, record) do
    case CasRecord.create(key, record) do
      {:ok, _created} ->
        :ok

      {:error, _reason} = error ->
        if match?({:ok, ^record}, CasRecord.get(key)), do: :ok, else: error
    end
  end

  defp exact_map_keys?(map, keys) when is_map(map),
    do: Enum.sort(Map.keys(map)) == Enum.sort(keys)

  defp exact_map_keys?(_map, _keys), do: false
  defp nonempty?(value), do: is_binary(value) and String.trim(value) != ""
  defp valid_sha256?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  defp padded_created_at(created_at),
    do: created_at |> Integer.to_string() |> String.pad_leading(13, "0")

  # Record hashes must be reproducible across OTP releases. Jason follows the
  # map's own iteration order, which above the 32-key flatmap boundary is a HAMT
  # implementation detail, so an OTP upgrade would silently invalidate every
  # historical hash. CanonicalJSON sorts keys, so the bytes are the record's.
  defp sha256(value) do
    value
    |> CanonicalJSON.encode!()
    |> CanonicalJSON.sha256()
  end
end
