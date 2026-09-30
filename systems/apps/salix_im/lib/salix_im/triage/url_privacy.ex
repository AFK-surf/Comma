defmodule SalixIM.Triage.URLPrivacy do
  @moduledoc """
  Structural HTTP(S) URL extraction and redaction for untrusted Triage text.

  Two separate obligations live here and must not be confused:

    * `extract_https_urls/1` names the URLs a caller may alias. A bare scheme
      with no host character after it is not a URL, so `https://).` yields
      nothing to alias rather than the empty-host string `https://` — aliasing
      that string would rewrite the scheme of every other URL in the text.
    * `redact_https_urls/2` must leave no scheme behind at all. It rewrites the
      extracted URLs longest-first, so `https://x.test` can never consume the
      prefix of `https://x.test/secret` and strand its path, and then sweeps any
      residual scheme substring — URL-shaped or not — to `link://redacted`.

  `residual_https_scheme?/1` is the fail-closed verifier a durable consumer
  runs: it asks the blunt question ("is there still an `https://` in here?")
  rather than the structural one, so a shape this module failed to parse cannot
  pass as redacted.
  """

  @slack_mrkdwn_link ~r/<(https?:\/\/[^>|]+)(?:\|[^>]*)?>/i
  # A scheme only starts a URL when a host character follows it.
  @raw_http_url ~r/\bhttps?:\/\/[A-Za-z0-9\-._~%]+[^\s<>"']*/i
  @bare_scheme ~r/https?:\/\//i
  @https_scheme ~r/https:\/\//i
  @trailing_punctuation ~r/[.,;:!?\)\]\}]+$/
  @bare_scheme_alias "link://redacted"

  @doc """
  Replaces every URL in `text`, then sweeps any scheme substring that survives.

  `replacement` is either one binary used for every URL, or a 1-arity function
  from the raw URL to its replacement (so distinct URLs can carry distinct
  aliases instead of collapsing into one).
  """
  @spec redact_https_urls(binary(), binary() | (binary() -> binary())) :: binary()
  def redact_https_urls(text, replacement) when is_binary(text) and is_binary(replacement),
    do: redact_https_urls(text, fn _url -> replacement end)

  def redact_https_urls(text, replacement_fun)
      when is_binary(text) and is_function(replacement_fun, 1) do
    text
    |> extract_https_urls()
    |> Enum.sort_by(&byte_size/1, :desc)
    |> Enum.reduce(text, &String.replace(&2, &1, replacement_fun.(&1)))
    |> then(&Regex.replace(@bare_scheme, &1, @bare_scheme_alias))
  end

  @doc "Whether `text` still names a structurally parseable HTTP(S) URL."
  @spec contains_https_url?(binary()) :: boolean()
  def contains_https_url?(text) when is_binary(text), do: extract_https_urls(text) != []
  def contains_https_url?(_text), do: false

  @doc """
  Fail-closed verifier: any residual `https://` substring at all.

  A durable consumer must not depend on this module's own parser agreeing that
  the leftover is a URL — a scheme that survived redaction is a redaction
  failure whatever shape follows it.
  """
  @spec residual_https_scheme?(term()) :: boolean()
  def residual_https_scheme?(text) when is_binary(text), do: Regex.match?(@https_scheme, text)
  def residual_https_scheme?(_text), do: true

  @spec canonical_https_url(binary()) :: {:ok, binary()} | :error
  def canonical_https_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, userinfo: nil} = uri
      when is_binary(scheme) and is_binary(host) and host != "" ->
        if String.downcase(scheme) == "https" do
          host = host |> String.downcase() |> String.trim_trailing(".")
          port = if uri.port == 443, do: nil, else: uri.port
          path = if uri.path in [nil, ""], do: "/", else: uri.path
          {:ok, URI.to_string(%{uri | scheme: "https", host: host, port: port, path: path})}
        else
          :error
        end

      _other ->
        :error
    end
  end

  def canonical_https_url(_url), do: :error

  @spec extract_https_urls(binary()) :: [binary()]
  def extract_https_urls(text) when is_binary(text) do
    slack_links =
      @slack_mrkdwn_link
      |> Regex.scan(text, capture: :all_but_first)
      |> Enum.map(&hd/1)

    generic_links =
      Regex.replace(@slack_mrkdwn_link, text, " ")
      |> then(&Regex.scan(@raw_http_url, &1, capture: :first))
      |> Enum.map(&hd/1)

    (slack_links ++ generic_links)
    |> Enum.map(&Regex.replace(@trailing_punctuation, &1, ""))
    |> Enum.filter(&hosted?/1)
    |> Enum.uniq()
  end

  def extract_https_urls(_text), do: []

  defp hosted?(url) do
    match?(
      %URI{scheme: scheme, host: host} when is_binary(scheme) and is_binary(host) and host != "",
      URI.parse(url)
    )
  end
end
