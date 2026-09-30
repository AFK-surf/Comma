defmodule SalixAgent.SiteId do
  @moduledoc """
  Agent-hosted website addressing — the Salix port of willow's
  `internal/agent/siteid.go` (Crockford-base32 agent ids for DNS-safe
  subdomains) and `internal/sites/scheme.go` (URL scheme picker).

  A public site host has willow's exact shape:

      {site-name}-{base32-agent-id}.{sites-domain}

  Salix agent ids are canonical `agt1_<tenant>_<group>_<agent>` ids. The three
  numeric segments are encoded as 24 bytes of Crockford base32, so the host
  token is DNS-safe and reversible without a secondary lookup index.

  The sites domain lives at `config :salix_agent, :sites_domain`
  (`SALIX_SITES_DOMAIN` / config.json `web.sites_domain`); like willow, an
  empty/nil domain disables host-based site serving and site URL synthesis.
  """

  # Crockford base32 (lowercase, no padding) — willow's CrockfordEncoding.
  @alphabet ~c"0123456789abcdefghjkmnpqrstvwxyz"
  @agent_segment_count 3
  @agent_segment_bytes 8
  @dns_label_max_bytes 63
  @encoded_agent_id_bytes @agent_segment_count * @agent_segment_bytes
  @encoded_agent_id_length div(@encoded_agent_id_bytes * 8 + 4, 5)
  @max_host_site_name_bytes @dns_label_max_bytes - @encoded_agent_id_length - 1

  alias SalixStore.Ids

  @doc "Configured wildcard sites domain, or nil when site hosting is disabled."
  @spec sites_domain() :: String.t() | nil
  def sites_domain do
    case Application.get_env(:salix_agent, :sites_domain) do
      domain when is_binary(domain) and domain != "" -> domain
      _ -> nil
    end
  end

  @doc """
  Configured port carried in synthesized LOCAL (http/`*.localhost`) site URLs
  — the dev endpoint answers on 4000, not 80. Returns nil when unset or
  redundant (80); https domains never carry it (`url_suffix/1`).
  """
  @spec sites_port() :: pos_integer() | nil
  def sites_port do
    case Application.get_env(:salix_agent, :sites_port) do
      port when is_integer(port) and port > 0 and port != 80 -> port
      _ -> nil
    end
  end

  @doc """
  Willow `sites.URLScheme`: local dev serves sites over HTTP under
  `*.localhost`; everything else (including empty input) is HTTPS.
  """
  @spec url_scheme(String.t() | nil) :: String.t()
  def url_scheme(sites_domain) do
    domain = String.downcase(String.trim(to_string(sites_domain || "")))

    if domain == "localhost" or String.ends_with?(domain, ".localhost") do
      "http"
    else
      "https"
    end
  end

  @doc """
  Encode a canonical Salix agent id to Crockford base32.
  """
  @spec encode(String.t()) :: {:ok, String.t()} | {:error, term()}
  def encode(agent_id) when is_binary(agent_id) do
    if Ids.valid_agent_id?(agent_id) do
      agent_id
      |> Ids.agent_body!()
      |> agent_body_to_bytes()
      |> case do
        {:ok, bytes} -> {:ok, encode_bytes(bytes)}
        {:error, _} = error -> error
      end
    else
      {:error, :invalid_agent_id}
    end
  end

  @doc """
  Decode a Crockford-base32 subdomain label back to the canonical agent id.
  """
  @spec decode(String.t()) :: {:ok, String.t()} | {:error, term()}
  def decode(encoded) when is_binary(encoded) do
    with {:ok, bytes} <- decode_bytes(encoded),
         @encoded_agent_id_bytes <- byte_size(bytes),
         {:ok, body} <- bytes_to_agent_body(bytes),
         {:ok, agent_id} <- Ids.agent_id_from_body(body) do
      {:ok, agent_id}
    else
      _ -> {:error, :invalid_encoded_id}
    end
  end

  @doc """
  Willow `isValidSiteName`: DNS-label safe — lowercase letters, digits and
  hyphens only, no leading/trailing hyphen.
  """
  @spec valid_site_name?(String.t()) :: boolean()
  def valid_site_name?(""), do: false

  def valid_site_name?(name) when is_binary(name) do
    not String.starts_with?(name, "-") and not String.ends_with?(name, "-") and
      name =~ ~r/^[a-z0-9-]+$/
  end

  def valid_site_name?(_), do: false

  @doc "Maximum ASCII site-name length that fits beside an encoded agent id."
  def max_host_site_name_bytes, do: @max_host_site_name_bytes

  @doc "Whether a site name can be represented by the host-based site URL."
  def valid_host_site_name?(name) when is_binary(name),
    do: valid_site_name?(name) and byte_size(name) <= @max_host_site_name_bytes

  def valid_host_site_name?(_name), do: false

  @doc """
  Public URL for a site of an agent under the configured sites domain
  (willow's `{scheme}://{site}-{b32}.{domain}` shape, plus `:{sites_port}`
  for local http domains), or nil when the domain is unconfigured or the
  agent id is not encodable.
  """
  @spec site_url(String.t(), String.t()) :: String.t() | nil
  def site_url(agent_id, site_name) do
    with domain when is_binary(domain) <- sites_domain(),
         true <- valid_host_site_name?(site_name),
         {:ok, encoded} <- encode(agent_id) do
      url_scheme(domain) <>
        "://" <> site_name <> "-" <> encoded <> "." <> domain <> url_suffix(domain)
    else
      _ -> nil
    end
  end

  # ":{port}" for local http domains with a configured non-default port;
  # https (real) domains always serve on 443 and never carry one.
  defp url_suffix(domain) do
    case {url_scheme(domain), sites_port()} do
      {"http", port} when is_integer(port) -> ":" <> Integer.to_string(port)
      _ -> ""
    end
  end

  @doc """
  Parse a Host header into `{site_name, encoded_agent_id_decoded}` — willow's
  `extractSiteInfo`. Returns `:error` when the host is not a site request.
  """
  @spec extract_site_info(String.t(), String.t()) :: {:ok, String.t(), String.t()} | :error
  def extract_site_info(host, sites_domain)
      when is_binary(host) and is_binary(sites_domain) do
    # Strip port.
    host =
      case String.split(host, ":") do
        [h | _] -> h
        _ -> host
      end

    suffix = "." <> sites_domain

    with true <- String.ends_with?(host, suffix),
         subdomain when subdomain != "" <-
           binary_part(host, 0, byte_size(host) - byte_size(suffix)),
         true <- byte_size(subdomain) <= @dns_label_max_bytes,
         # Split on the LAST hyphen: left = site name, right = base32 agent id.
         idx when is_integer(idx) and idx > 0 <- last_hyphen(subdomain),
         site_name <- binary_part(subdomain, 0, idx),
         encoded <- binary_part(subdomain, idx + 1, byte_size(subdomain) - idx - 1),
         true <- valid_host_site_name?(site_name),
         {:ok, agent_id} <- decode(encoded) do
      {:ok, site_name, agent_id}
    else
      _ -> :error
    end
  end

  @doc """
  Willow's `<agent-config format="yaml">` system-prompt block: `agent_id`,
  `agent_id_base32`, `agent_website_url_template` (when the sites domain is
  configured). Time is supplied by TimeContext. Keys are emitted in willow's (alphabetical —
  Go `yaml.Marshal` of a map) order.
  """
  @spec agent_config_block(String.t()) :: String.t()
  def agent_config_block(agent_id) do
    encoded =
      case encode(agent_id) do
        {:ok, e} -> e
        _ -> ""
      end

    entries = [
      {"agent_id", agent_id},
      {"agent_id_base32", encoded}
    ]

    entries =
      case sites_domain() do
        domain when is_binary(domain) ->
          template =
            url_scheme(domain) <>
              "://{site-name}-" <> encoded <> "." <> domain <> url_suffix(domain)

          entries ++ [{"agent_website_url_template", template}]

        _ ->
          entries
      end

    yaml =
      entries
      |> Enum.map(fn {k, v} -> "#{k}: #{v}\n" end)
      |> Enum.join()

    "<agent-config format=\"yaml\">\n" <> yaml <> "\n</agent-config>"
  end

  # ---- Crockford base32 ----

  defp encode_bytes(bytes) do
    for <<chunk::size(5) <- pad_bits(bytes)>>, into: "", do: <<Enum.at(@alphabet, chunk)>>
  end

  defp pad_bits(bytes) do
    bits = bit_size(bytes)
    pad = rem(5 - rem(bits, 5), 5)
    <<bytes::bitstring, 0::size(pad)>>
  end

  defp decode_bytes(encoded) do
    encoded
    |> String.to_charlist()
    |> Enum.reduce_while(<<>>, fn ch, acc ->
      case Enum.find_index(@alphabet, &(&1 == ch)) do
        nil -> {:halt, :error}
        v -> {:cont, <<acc::bitstring, v::size(5)>>}
      end
    end)
    |> case do
      :error ->
        :error

      bits ->
        whole = div(bit_size(bits), 8) * 8
        pad = bit_size(bits) - whole
        <<bytes::bitstring-size(^whole), trailing::size(^pad)>> = bits
        # Go's base32 rejects non-zero trailing padding bits.
        if trailing == 0, do: {:ok, bytes}, else: :error
    end
  end

  defp agent_body_to_bytes(body) do
    case String.split(body, "_") do
      [tenant, group, agent] -> segments_to_bytes([tenant, group, agent], <<>>)
      _ -> {:error, :invalid_agent_id}
    end
  end

  defp segments_to_bytes([], bytes), do: {:ok, bytes}

  defp segments_to_bytes([segment | rest], bytes) do
    case Integer.parse(segment) do
      {integer, ""} when integer >= 0 and integer <= 18_446_744_073_709_551_615 ->
        segments_to_bytes(rest, <<bytes::binary, integer::unsigned-big-64>>)

      _ ->
        {:error, :invalid_agent_id}
    end
  end

  defp bytes_to_agent_body(bytes) when byte_size(bytes) == @encoded_agent_id_bytes do
    body =
      for <<segment::unsigned-big-64 <- bytes>> do
        segment |> Integer.to_string() |> String.pad_leading(19, "0")
      end
      |> Enum.join("_")

    {:ok, body}
  end

  defp bytes_to_agent_body(_bytes), do: {:error, :invalid_agent_id}

  defp last_hyphen(subdomain) do
    case :binary.matches(subdomain, "-") do
      [] -> nil
      matches -> matches |> List.last() |> elem(0)
    end
  end
end
