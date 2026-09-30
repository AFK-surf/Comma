defmodule SalixSignalProto.ContactDiscovery.Collateral do
  @moduledoc """
  Intel collateral documents in the attestation endorsements (CRS-11 §5.5):
  the TCB info and the QE identity. Each document is
  `{"<body key>": <object>, "signature": "<128 hex characters>"}`, signed
  with ECDSA P-256/SHA-256 (`r || s`) over the exact bytes of the body value
  as they appear in the document.

  `tcb_info/1` and `qe_identity/1` parse and check the structure only;
  `SalixSignalProto.ContactDiscovery.Attestation` checks the signatures and
  the values.
  """

  @statuses ~w(UpToDate SWHardeningNeeded ConfigurationNeeded ConfigurationAndSWHardeningNeeded
               OutOfDate OutOfDateConfigurationNeeded Revoked)
  @qe_statuses ~w(UpToDate OutOfDate Revoked)

  @doc """
  Parses a TCB info document. Returns `{:ok, %{signed: bytes, signature:
  <<_::512>>, next_update:, evaluation_data_number:, fmspc: <<_::48>>,
  pce_id: <<_::16>>, levels: [%{components: [16], pce_svn:, status:,
  advisories: [String.t()]}]}}`.
  """
  @spec tcb_info(binary()) :: {:ok, map()} | {:error, :invalid_tcb_info}
  def tcb_info(document) do
    with {:ok, raw, signature} <- signed_body(document, "tcbInfo"),
         {:ok, %{} = info} <- JSON.decode(raw),
         version when version in [2, 3] <- info["version"],
         0 <- info["tcbType"],
         {:ok, next_update} <- time(info["nextUpdate"]),
         number when is_integer(number) <- info["tcbEvaluationDataNumber"],
         {:ok, fmspc} <- hex(info["fmspc"], 6),
         {:ok, pce_id} <- hex(info["pceId"], 2),
         levels when is_list(levels) <- info["tcbLevels"],
         {:ok, levels} <- map_all(levels, &tcb_level(version, &1)) do
      {:ok,
       %{
         signed: raw,
         signature: signature,
         next_update: next_update,
         evaluation_data_number: number,
         fmspc: fmspc,
         pce_id: pce_id,
         levels: levels
       }}
    else
      _ -> {:error, :invalid_tcb_info}
    end
  end

  defp tcb_level(version, %{"tcb" => %{} = tcb, "tcbStatus" => status} = level)
       when status in @statuses do
    with {:ok, components} <- components(version, tcb),
         pce_svn when is_integer(pce_svn) and pce_svn >= 0 <- tcb["pcesvn"],
         advisories when is_list(advisories) <- Map.get(level, "advisoryIDs", []),
         true <- Enum.all?(advisories, &is_binary/1) do
      {:ok, %{components: components, pce_svn: pce_svn, status: status, advisories: advisories}}
    else
      _ -> :error
    end
  end

  defp tcb_level(_version, _level), do: :error

  defp components(2, tcb) do
    keys = for i <- 1..16, do: "sgxtcbcomp" <> String.pad_leading("#{i}", 2, "0") <> "svn"
    svns(Enum.map(keys, &tcb[&1]))
  end

  defp components(3, %{"sgxtcbcomponents" => list}) when length(list) == 16 do
    svns(
      Enum.map(list, fn
        %{"svn" => svn} -> svn
        _ -> nil
      end)
    )
  end

  defp components(_version, _tcb), do: :error

  defp svns(values) do
    if Enum.all?(values, &(is_integer(&1) and &1 >= 0)), do: {:ok, values}, else: :error
  end

  @doc """
  Parses a QE identity document. Returns `{:ok, %{signed:, signature:,
  next_update:, evaluation_data_number:, miscselect: <<_::32>>,
  miscselect_mask:, attributes: <<_::128>>, attributes_mask:, mrsigner:
  <<_::256>>, isvprodid:, levels: [%{isvsvn:, status:}]}}`.
  """
  @spec qe_identity(binary()) :: {:ok, map()} | {:error, :invalid_qe_identity}
  def qe_identity(document) do
    with {:ok, raw, signature} <- signed_body(document, "enclaveIdentity"),
         {:ok, %{} = identity} <- JSON.decode(raw),
         "QE" <- identity["id"],
         2 <- identity["version"],
         {:ok, next_update} <- time(identity["nextUpdate"]),
         number when is_integer(number) <- identity["tcbEvaluationDataNumber"],
         {:ok, miscselect} <- hex(identity["miscselect"], 4),
         {:ok, miscselect_mask} <- hex(identity["miscselectMask"], 4),
         {:ok, attributes} <- hex(identity["attributes"], 16),
         {:ok, attributes_mask} <- hex(identity["attributesMask"], 16),
         {:ok, mrsigner} <- hex(identity["mrsigner"], 32),
         isvprodid when is_integer(isvprodid) <- identity["isvprodid"],
         levels when is_list(levels) <- identity["tcbLevels"],
         {:ok, levels} <- map_all(levels, &qe_level/1) do
      {:ok,
       %{
         signed: raw,
         signature: signature,
         next_update: next_update,
         evaluation_data_number: number,
         miscselect: miscselect,
         miscselect_mask: miscselect_mask,
         attributes: attributes,
         attributes_mask: attributes_mask,
         mrsigner: mrsigner,
         isvprodid: isvprodid,
         levels: levels
       }}
    else
      _ -> {:error, :invalid_qe_identity}
    end
  end

  defp qe_level(%{"tcb" => %{"isvsvn" => isvsvn}, "tcbStatus" => status})
       when is_integer(isvsvn) and status in @qe_statuses,
       do: {:ok, %{isvsvn: isvsvn, status: status}}

  defp qe_level(_level), do: :error

  # --- Signed document -----------------------------------------------------

  # Returns the raw bytes of the value of `key` in the top-level object and
  # the decoded signature. The document must be valid JSON with exactly one
  # `key` member and a `signature` member of 128 hex characters.
  defp signed_body(document, key) do
    with {:ok, %{"signature" => signature_hex}} <- JSON.decode(document),
         {:ok, signature} <- hex(signature_hex, 64),
         {:ok, members} <- top_level_members(document),
         [raw] <- for({^key, raw} <- members, do: raw) do
      {:ok, raw, signature}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  # Raw spans of the members of a top-level JSON object, which is already
  # known to be valid JSON.
  defp top_level_members(document) do
    pos = skip_ws(document, 0)

    case byte_at(document, pos) do
      ?{ -> members(document, skip_ws(document, pos + 1), [])
      _ -> :error
    end
  end

  defp members(doc, pos, acc) do
    case byte_at(doc, pos) do
      ?} ->
        {:ok, Enum.reverse(acc)}

      ?" ->
        key_end = scan_string(doc, pos + 1)
        {:ok, key} = JSON.decode(binary_part(doc, pos, key_end - pos))
        colon = skip_ws(doc, key_end)
        ?: = byte_at(doc, colon)
        value_start = skip_ws(doc, colon + 1)
        value_end = scan_value(doc, value_start)
        member = {key, binary_part(doc, value_start, value_end - value_start)}
        next = skip_ws(doc, value_end)

        case byte_at(doc, next) do
          ?, -> members(doc, skip_ws(doc, next + 1), [member | acc])
          ?} -> {:ok, Enum.reverse([member | acc])}
        end
    end
  end

  defp scan_value(doc, pos) do
    case byte_at(doc, pos) do
      ?" -> scan_string(doc, pos + 1)
      c when c in [?{, ?[] -> scan_nested(doc, pos + 1, 1)
      _ -> scan_scalar(doc, pos)
    end
  end

  defp scan_nested(_doc, pos, 0), do: pos

  defp scan_nested(doc, pos, depth) do
    case byte_at(doc, pos) do
      ?" -> scan_nested(doc, scan_string(doc, pos + 1), depth)
      c when c in [?{, ?[] -> scan_nested(doc, pos + 1, depth + 1)
      c when c in [?}, ?]] -> scan_nested(doc, pos + 1, depth - 1)
      _ -> scan_nested(doc, pos + 1, depth)
    end
  end

  # Returns the position after the closing quote.
  defp scan_string(doc, pos) do
    case byte_at(doc, pos) do
      ?\\ -> scan_string(doc, pos + 2)
      ?" -> pos + 1
      _ -> scan_string(doc, pos + 1)
    end
  end

  defp scan_scalar(doc, pos) do
    case byte_at(doc, pos) do
      c when c in [?,, ?}, ?], ?\s, ?\t, ?\n, ?\r] or c == nil -> pos
      _ -> scan_scalar(doc, pos + 1)
    end
  end

  defp skip_ws(doc, pos) do
    if byte_at(doc, pos) in [?\s, ?\t, ?\n, ?\r], do: skip_ws(doc, pos + 1), else: pos
  end

  defp byte_at(doc, pos) when pos < byte_size(doc), do: :binary.at(doc, pos)
  defp byte_at(_doc, _pos), do: nil

  # --- Values --------------------------------------------------------------

  defp time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, DateTime.to_unix(datetime)}
      _ -> :error
    end
  end

  defp time(_value), do: :error

  defp hex(value, size) when is_binary(value) and byte_size(value) == 2 * size do
    case Base.decode16(value, case: :mixed) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> :error
    end
  end

  defp hex(_value, _size), do: :error

  defp map_all(list, fun) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        _ -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      :error -> :error
    end
  end
end
