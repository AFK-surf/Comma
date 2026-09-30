defmodule SalixStore.SigV4 do
  @moduledoc """
  Minimal AWS Signature Version 4 signer for S3 (path-style).

  We own this narrow layer deliberately: the protocol surface
  we depend on is small but correctness-critical — `If-Match` / `If-None-Match`
  on PUT *and* DELETE, `x-amz-meta-*`, ranged GET, and paginated LIST. We sign
  exactly the headers we send, so conditional and metadata headers are always
  covered by the signature.

  Returns the full header list (including `Authorization`) to attach to the
  outgoing request. The payload hash is computed over the whole body
  (S3 single-shot uploads; no streaming-chunked signing needed here).
  """

  @doc """
  Sign a request. `headers` is a list of `{name, value}` with lowercase names
  expected for canonicalization (we downcase defensively). Returns the header
  list to send, including the computed auth headers.

  `now` is a `{date, time}` tuple from `:calendar.universal_time/0`; injectable
  for deterministic tests.
  """
  @spec sign(
          String.t(),
          String.t(),
          [{String.t(), String.t()}],
          iodata(),
          SalixStore.Config.t(),
          :calendar.datetime() | nil
        ) :: [{String.t(), String.t()}]
  def sign(method, url, headers, body, cfg, now \\ nil, payload_hash_override \\ nil) do
    uri = URI.parse(url)
    variant = variant(cfg)
    {amz_date, date_stamp} = timestamps(now)
    payload_hash = payload_hash_override || sha256_hex(body)

    host =
      case uri.port do
        nil -> uri.host
        80 when uri.scheme == "http" -> uri.host
        443 when uri.scheme == "https" -> uri.host
        port -> "#{uri.host}:#{port}"
      end

    base_headers =
      headers
      |> Enum.map(fn {k, v} -> {String.downcase(k), to_string(v)} end)
      |> upsert("host", host)
      |> upsert(variant.date_header, amz_date)
      |> upsert(variant.content_sha256_header, payload_hash)

    sorted = Enum.sort_by(base_headers, fn {k, _} -> k end)
    signed_headers = sorted |> Enum.map(fn {k, _} -> k end) |> Enum.join(";")

    canonical_headers =
      sorted
      |> Enum.map(fn {k, v} -> "#{k}:#{String.trim(v)}\n" end)
      |> Enum.join()

    canonical_query = canonical_query_string(uri.query)
    canonical_uri = canonical_uri(uri.path)

    canonical_request =
      [
        method,
        canonical_uri,
        canonical_query,
        canonical_headers,
        signed_headers,
        payload_hash
      ]
      |> Enum.join("\n")

    scope = "#{date_stamp}/#{cfg.region}/#{variant.service}/#{variant.request_type}"

    string_to_sign =
      [
        variant.algorithm,
        amz_date,
        scope,
        sha256_hex(canonical_request)
      ]
      |> Enum.join("\n")

    signing_key = signing_key(cfg.secret_access_key, date_stamp, cfg.region, variant)
    signature = hmac(signing_key, string_to_sign) |> Base.encode16(case: :lower)

    authorization =
      "#{variant.algorithm} Credential=#{cfg.access_key_id}/#{scope}, " <>
        "SignedHeaders=#{signed_headers}, Signature=#{signature}"

    base_headers ++ [{"authorization", authorization}]
  end

  # ---- helpers ----

  defp variant(%{atomic_operations: :gcp}) do
    %{
      algorithm: "GOOG4-HMAC-SHA256",
      key_prefix: "GOOG4",
      service: "storage",
      request_type: "goog4_request",
      date_header: "x-goog-date",
      content_sha256_header: "x-goog-content-sha256"
    }
  end

  defp variant(_cfg) do
    %{
      algorithm: "AWS4-HMAC-SHA256",
      key_prefix: "AWS4",
      service: "s3",
      request_type: "aws4_request",
      date_header: "x-amz-date",
      content_sha256_header: "x-amz-content-sha256"
    }
  end

  # Upsert a string-keyed header (case-insensitive on the already-downcased list).
  defp upsert(headers, key, value) do
    [{key, value} | Enum.reject(headers, fn {k, _} -> k == key end)]
  end

  defp timestamps(nil), do: timestamps(:calendar.universal_time())

  defp timestamps({{y, mo, d}, {h, mi, s}}) do
    amz_date =
      :io_lib.format("~4..0B~2..0B~2..0BT~2..0B~2..0B~2..0BZ", [y, mo, d, h, mi, s])
      |> IO.iodata_to_binary()

    date_stamp = :io_lib.format("~4..0B~2..0B~2..0B", [y, mo, d]) |> IO.iodata_to_binary()
    {amz_date, date_stamp}
  end

  # S3 canonical URI: URI-encode each path segment except the slashes,
  # leaving already-safe chars. The request URL is already path-encoded by the
  # S3 client, so decode it before canonicalization to avoid signing `%40` as
  # `%2540` while the HTTP request still sends `%40`.
  defp canonical_uri(nil), do: "/"
  defp canonical_uri(""), do: "/"

  defp canonical_uri(path) do
    path
    |> URI.decode()
    |> String.split("/")
    |> Enum.map(&uri_encode(&1, false))
    |> Enum.join("/")
  end

  defp canonical_query_string(nil), do: ""

  defp canonical_query_string(query) do
    query
    |> URI.query_decoder()
    |> Enum.map(fn {k, v} -> {uri_encode(k, true), uri_encode(v, true)} end)
    |> Enum.sort()
    |> Enum.map(fn {k, v} -> "#{k}=#{v}" end)
    |> Enum.join("&")
  end

  # RFC 3986 unreserved set; AWS sigv4 encodes everything else.
  defp uri_encode(str, encode_slash?) do
    str
    |> :binary.bin_to_list()
    |> Enum.map(fn c ->
      cond do
        c in ?A..?Z or c in ?a..?z or c in ?0..?9 or c in [?-, ?_, ?., ?~] ->
          <<c>>

        c == ?/ and not encode_slash? ->
          "/"

        true ->
          "%" <> (Integer.to_string(c, 16) |> String.upcase() |> String.pad_leading(2, "0"))
      end
    end)
    |> Enum.join()
  end

  defp signing_key(secret, date_stamp, region, variant) do
    (variant.key_prefix <> secret)
    |> hmac(date_stamp)
    |> hmac(region)
    |> hmac(variant.service)
    |> hmac(variant.request_type)
  end

  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)
  defp sha256_hex(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
end
