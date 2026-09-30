defmodule SalixAnalytics.EventArchive.Item do
  @moduledoc """
  The wire form of one archived agent-loop event: a ClickHouse row.

  Every column except `e` is the PLAINTEXT header, stored as a real column so
  the archive is navigable, purgeable and gap-checkable WITHOUT keys — a tenant
  purge, an auditor fetching one session, and a completeness check all have to
  work against rows nobody in the cluster can decrypt.

  `e` is a complete, standalone age file, base64-encoded. That means an operator
  opens one item with tools they already have:

      clickhouse-client -q "SELECT e FROM agent_event_archive \\
        WHERE session_id = 'ses1_…' ORDER BY seq LIMIT 1" \\
        | base64 -d | age -d -i key.txt

  Base64 rather than raw bytes because rows are ingested as JSONEachRow, whose
  String values must be valid UTF-8; an age file is arbitrary bytes. The 33%
  inflation is the documented cost of using the same narrow HTTP sink as the
  rest of the analytics path.

  ## Header integrity

  age has no AAD, so unlike a bespoke envelope the plaintext header cannot be
  cryptographically bound to the ciphertext at the AEAD layer. Instead a
  canonical COPY of the header is sealed inside the payload, and
  `mix salix.archive.open` compares the two. Tampering is therefore detected at
  read time by mismatch rather than by a failed decrypt — and note this is now
  strictly more valuable than it was against object storage: the header columns
  are separately mutable by anyone with ClickHouse write access (`ALTER TABLE …
  UPDATE`), where before an object was rewritten wholesale. The sealed copy is
  the only thing that makes a doctored `session_id` or `boundary` detectable.

  Canonicalization (recursively sorted keys) matches `SalixStore.ArchiveLog`,
  so the sealed copy encodes identically on any writer and any OTP release.
  """

  alias SalixStore.Age

  @wire_version 1

  @type header :: %{String.t() => term()}

  @doc """
  Build the plaintext header for one event.

  `attrs` carries the stream position and identity; `payload` is only measured
  here, never inspected.
  """
  @spec header(map(), non_neg_integer()) :: header()
  def header(attrs, payload_bytes) do
    %{
      "v" => @wire_version,
      # `stream` is derived from a session or agent id, so it inherits their
      # provenance: archived at stage time, BEFORE validation. Sanitized like
      # the other identifiers, and for a sharper reason than they need it —
      # `Completeness` quotes the stream back into a WHERE clause, and its
      # quoting strips control characters, so an unsanitized stream would
      # simply fail to match itself and the run's gap detail would vanish.
      "stream" => identifier(attrs.stream),
      "writer" => identifier(attrs.writer),
      "seq" => attrs.seq,
      "ts" => timestamp(attrs[:ts]),
      # Bounded: session_id in particular arrives from outside and is archived
      # at stage time, BEFORE validation, so an arbitrary string would otherwise
      # land verbatim in a plaintext, key-free index.
      "tenant_id" => identifier(attrs[:tenant_id]),
      "agent_id" => identifier(attrs[:agent_id]),
      "session_id" => identifier(attrs[:session_id]),
      "round_id" => identifier(attrs[:round_id]),
      "boundary" => to_string(attrs.boundary),
      "direction" => to_string(attrs.direction),
      "bytes" => payload_bytes,
      "app_revision" => to_string(attrs[:app_revision] || ""),
      "key_ids" => attrs[:key_ids] || []
    }
  end

  @doc """
  Seal one event into its ClickHouse row.

  The sealed plaintext is `{"h": <canonical header>, "p": <payload>}` so a
  reader can verify the header columns it navigated by against the copy that was
  actually encrypted.
  """
  @spec seal(map(), term(), [SalixAnalytics.EventArchive.Recipients.recipient(), ...]) ::
          {:ok, map()} | {:error, term()}
  def seal(attrs, payload, recipients) do
    encoded_payload = Jason.encode!(payload)
    key_ids = Enum.map(recipients, & &1.key_id)
    header = attrs |> Map.put(:key_ids, key_ids) |> header(byte_size(encoded_payload))

    sealed_plaintext =
      Jason.encode!(%{"h" => canonicalize(header), "p" => payload}, maps: :strict)

    case Age.encrypt(sealed_plaintext, Enum.map(recipients, & &1.key)) do
      {:ok, age_file} ->
        {:ok, row(header, Base.encode64(age_file, padding: false))}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  The ClickHouse row for a header plus its base64 age file.

  This is the only place the header-to-column mapping is written. Nothing pins
  it at migrate time — the migration is plain DDL — so a column renamed here
  and not there fails at INSERT, loudly. What is checked is the part that
  fails SILENTLY: `SalixAnalytics.EventArchive.Sink.readiness/1` probes the
  engine, partition key and sorting key, because a wrong sorting key on a
  ReplacingMergeTree merges rows away rather than rejecting them.
  """
  @spec row(header(), binary()) :: map()
  def row(header, encoded_age_file) do
    %{
      "event_date" => event_date(header["ts"]),
      "tenant_id" => header["tenant_id"] || "",
      "stream" => header["stream"],
      "writer" => header["writer"] || "",
      "seq" => header["seq"],
      "ts" => header["ts"],
      "agent_id" => header["agent_id"] || "",
      "session_id" => header["session_id"] || "",
      "round_id" => header["round_id"] || "",
      "boundary" => header["boundary"],
      "direction" => header["direction"],
      "payload_bytes" => header["bytes"] || 0,
      "app_revision" => header["app_revision"] || "",
      "key_ids" => header["key_ids"] || [],
      "wire_version" => header["v"] || @wire_version,
      "e" => encoded_age_file
    }
  end

  @doc """
  Recover the plaintext header from a row read back out of ClickHouse.

  `seq` and `payload_bytes` are coerced back to integers. ClickHouse renders
  UInt64 as a JSON *string* whenever `output_format_json_quote_64bit_integers`
  is on — which is the documented default on many builds — so without this the
  recovered header holds `"42"` where the sealed copy holds `42`, every
  comparison in `open/2` reports a mismatch, and `mix salix.archive.open`
  refuses every item it is given.

  That would have disabled the archive's only tamper detection, and it is
  invisible on a server configured the other way: the round-trip test passed
  locally for exactly that reason. `Sink` also pins the setting on reads, but
  the coercion is what makes this correct regardless of who is serving.
  """
  @spec header_of_row(map()) :: header()
  def header_of_row(row) do
    %{
      "v" => row["wire_version"],
      "stream" => row["stream"],
      "writer" => row["writer"],
      "seq" => integer(row["seq"]),
      "ts" => row["ts"],
      "tenant_id" => row["tenant_id"],
      "agent_id" => row["agent_id"],
      "session_id" => row["session_id"],
      "round_id" => row["round_id"],
      "boundary" => row["boundary"],
      "direction" => row["direction"],
      "bytes" => integer(row["payload_bytes"]),
      "app_revision" => row["app_revision"],
      "key_ids" => row["key_ids"] || []
    }
  end

  @doc """
  Open one row with an age identity. Tooling and tests only.

  Returns `{:ok, header, payload, :verified}` when the sealed header copy
  matches the header columns, or `{:ok, header, payload, {:header_mismatch,
  sealed}}` when it does not. Callers decide what a mismatch means; nothing in
  the runtime calls this.
  """
  @spec open(map(), binary()) ::
          {:ok, header(), term(), :verified | {:header_mismatch, header()}} | {:error, term()}
  def open(row, identity) when is_map(row) do
    plain_header = header_of_row(row)

    with {:ok, age_file} <- Age.decode64_canonical(row["e"] || ""),
         {:ok, sealed_json} <- Age.decrypt(age_file, identity),
         {:ok, %{"h" => sealed_header, "p" => payload}} <- Jason.decode(sealed_json) do
      verdict =
        if canonicalize(sealed_header) == canonicalize(plain_header) do
          :verified
        else
          {:header_mismatch, sealed_header}
        end

      {:ok, plain_header, payload, verdict}
    else
      :error -> {:error, :bad_base64}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:malformed_item, other}}
    end
  end

  @doc """
  Recursively sort map keys so identical content encodes to identical bytes.

  Same contract as `SalixStore.ArchiveLog.canonicalize/1`; kept here rather
  than reused because that module's is private to its own wire form.
  """
  @spec canonicalize(term()) :: term()
  def canonicalize(map) when is_map(map) and not is_struct(map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), canonicalize(value)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Jason.OrderedObject.new()
  end

  def canonicalize(list) when is_list(list), do: Enum.map(list, &canonicalize/1)
  def canonicalize(other), do: other

  # ClickHouse may render UInt64 as a quoted string; the sealed copy always
  # holds an integer. Coerce so the two are comparable.
  defp integer(value) when is_integer(value), do: value

  defp integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> value
    end
  end

  defp integer(value), do: value

  @identifier_max 256

  defp identifier(nil), do: ""

  defp identifier(value) do
    value
    |> to_string()
    |> String.replace(~r/[[:cntrl:]]/, "")
    |> String.slice(0, @identifier_max)
  end

  defp timestamp(nil), do: DateTime.utc_now() |> DateTime.to_iso8601()
  defp timestamp(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp timestamp(value) when is_binary(value), do: value

  # The UTC calendar date of the item's own instant, never the flush time — a
  # batch straddling midnight must not land items in the wrong partition, or a
  # date-scoped purge and every pruned read would miss them.
  defp event_date(%DateTime{} = dt), do: dt |> DateTime.to_date() |> Date.to_iso8601()

  defp event_date(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> dt |> DateTime.to_date() |> Date.to_iso8601()
      _ -> Date.utc_today() |> Date.to_iso8601()
    end
  end

  defp event_date(_), do: Date.utc_today() |> Date.to_iso8601()
end
