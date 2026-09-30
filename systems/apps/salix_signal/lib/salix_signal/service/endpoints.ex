defmodule SalixSignal.Service.Endpoints do
  @moduledoc """
  Signal service hosts and TLS trust (CRS-01 sections 2 and 3).

  Signal services present certificates that chain to a private Signal root,
  not to public web roots. The client pins the two roots in
  `signal_roots.pem` for every Signal-rooted host and does not use the
  operating-system trust store for them (CRS-01 section 3.1). Root A signs
  the current leaves, including Ed25519 leaves on the chat hosts; root B is
  held for future leaf rotation (section 3.2).

  Comma uses the chat service over HTTP/1.1 with the WebSocket upgrade at
  `chat.signal.org` (owner decision recorded in CRS-01).
  """

  @roots_path Path.join(__DIR__, "signal_roots.pem")
  @external_resource @roots_path

  @roots @roots_path
         |> File.read!()
         |> :public_key.pem_decode()
         |> Enum.map(fn {:Certificate, der, :not_encrypted} -> der end)

  @hosts %{
    production: %{
      chat: "chat.signal.org",
      storage: "storage.signal.org",
      cdn0: "cdn.signal.org",
      cdn2: "cdn2.signal.org",
      cdn3: "cdn3.signal.org",
      cdsi: "cdsi.signal.org"
    },
    staging: %{
      chat: "chat.staging.signal.org",
      storage: "storage-staging.signal.org",
      cdn0: "cdn-staging.signal.org",
      cdn2: "cdn2-staging.signal.org",
      cdn3: "cdn3-staging.signal.org",
      cdsi: "cdsi.staging.signal.org"
    }
  }

  @type environment :: :production | :staging
  @type service :: :chat | :storage | :cdn0 | :cdn2 | :cdn3 | :cdsi

  @doc "The host of `service` in `environment`. All services listen on port 443."
  @spec host(environment(), service()) :: String.t()
  def host(environment, service), do: @hosts |> Map.fetch!(environment) |> Map.fetch!(service)

  @doc "DER encodings of the pinned Signal roots A and B."
  @spec pinned_roots() :: [binary()]
  def pinned_roots, do: @roots

  @doc """
  TLS options for a connection to a Signal-rooted host.

  The peer must chain to one of `roots` (default: the pinned roots) and its
  certificate must name the host. The chat host is reached with TLS 1.3 only
  (CRS-01 section 3.3); pass `versions:` to widen it for other hosts.
  """
  @spec tls_options(keyword()) :: keyword()
  def tls_options(opts \\ []) do
    [
      verify: :verify_peer,
      cacerts: Keyword.get(opts, :roots, @roots),
      versions: Keyword.get(opts, :versions, [:"tlsv1.3"]),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
  end
end
