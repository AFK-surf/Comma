defmodule SalixAgent.HttpDigestAuth do
  @moduledoc """
  HTTP Digest access authentication (RFC 7616, compatible with RFC 2617) for
  `device.lan_request` (`auth.type: "http_digest"`): the `Authorization` header
  that answers a `401` with a `WWW-Authenticate: Digest` challenge.

  Network cameras serve snapshots behind Digest. Salix computes the answer at
  dispatch from a saved password, so the password never enters the call or its
  result. Algorithms `MD5`, `MD5-sess`, `SHA-256` and `SHA-256-sess` are
  supported, with `qop` `auth` or no `qop`.
  """

  @doc """
  The Digest challenge in `www_authenticate` (a header value or a list of
  them), as a map of lowercase parameter names; nil when there is none.
  """
  @spec challenge(String.t() | [String.t()] | nil) :: map() | nil
  def challenge(values) when is_list(values), do: Enum.find_value(values, &challenge/1)

  # One value may list several challenges (`Basic realm="x", Digest realm=…`);
  # the Digest one runs up to the next `, <scheme> <param>=`.
  def challenge(value) when is_binary(value) do
    case Regex.run(
           ~r/(?:^|,)\s*digest\s+(.*?)(?=,\s*[A-Za-z0-9!#$%&'*+.^_`|~-]+\s+[A-Za-z0-9!#$%&'*+.^_`|~-]+\s*=|$)/is,
           value,
           capture: :all_but_first
         ) do
      [params] -> params(params)
      nil -> nil
    end
  end

  def challenge(_value), do: nil

  defp params(params) do
    ~r/([A-Za-z-]+)\s*=\s*(?:"((?:[^"\\]|\\.)*)"|([^\s,]+))/
    |> Regex.scan(params)
    |> Map.new(fn
      [_, key, quoted] -> {String.downcase(key), String.replace(quoted, ~r/\\(.)/, "\\1")}
      [_, key, "", token] -> {String.downcase(key), token}
    end)
    |> then(&if(is_binary(&1["nonce"]) and is_binary(&1["realm"]), do: &1))
  end

  @doc """
  The `Authorization` header value for `method` on `uri` (path and query;
  for RTSP the request URL). `algorithm` is echoed only when the challenge
  names one: a TP-LINK camera that sends none answers a client that sends
  none (captured 2026-10-09).
  `opts` fixes `:cnonce` for tests. Returns `{:error, :unsupported}` for an
  algorithm or `qop` this module does not implement.
  """
  @spec authorization(map(), String.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, :unsupported}
  def authorization(challenge, method, uri, username, password, opts \\ []) do
    algorithm = Map.get(challenge, "algorithm", "MD5")
    qops = challenge |> Map.get("qop", "") |> String.split(~r/\s*,\s*/, trim: true)

    with {:ok, hash, sess?} <- algorithm(algorithm),
         {:ok, qop} <- qop(qops) do
      realm = challenge["realm"]
      nonce = challenge["nonce"]

      cnonce =
        Keyword.get_lazy(opts, :cnonce, fn ->
          Base.encode16(SystemsRuntime.Proc.random_bytes(8), case: :lower)
        end)

      nc = "00000001"

      ha1 = hash.("#{username}:#{realm}:#{password}")
      ha1 = if sess?, do: hash.("#{ha1}:#{nonce}:#{cnonce}"), else: ha1
      ha2 = hash.("#{method}:#{uri}")

      response =
        if qop,
          do: hash.("#{ha1}:#{nonce}:#{nc}:#{cnonce}:#{qop}:#{ha2}"),
          else: hash.("#{ha1}:#{nonce}:#{ha2}")

      fields =
        [
          {"username", quoted(username)},
          {"realm", quoted(realm)},
          {"nonce", quoted(nonce)},
          {"uri", quoted(uri)}
        ] ++
          if(challenge["algorithm"], do: [{"algorithm", algorithm}], else: []) ++
          [{"response", quoted(response)}] ++
          if(challenge["opaque"], do: [{"opaque", quoted(challenge["opaque"])}], else: []) ++
          if(qop, do: [{"qop", qop}, {"nc", nc}], else: []) ++
          if(qop || sess?, do: [{"cnonce", quoted(cnonce)}], else: [])

      {:ok, "Digest " <> Enum.map_join(fields, ", ", fn {key, value} -> "#{key}=#{value}" end)}
    end
  end

  defp algorithm(name) do
    case String.upcase(name) do
      "MD5" -> {:ok, &hex(:md5, &1), false}
      "MD5-SESS" -> {:ok, &hex(:md5, &1), true}
      "SHA-256" -> {:ok, &hex(:sha256, &1), false}
      "SHA-256-SESS" -> {:ok, &hex(:sha256, &1), true}
      _ -> {:error, :unsupported}
    end
  end

  defp qop([]), do: {:ok, nil}

  defp qop(qops) do
    if "auth" in qops, do: {:ok, "auth"}, else: {:error, :unsupported}
  end

  defp hex(type, data), do: :crypto.hash(type, data) |> Base.encode16(case: :lower)

  defp quoted(value), do: ~s("#{String.replace(value, ~r/(["\\])/, "\\\\\\1")}")
end
