defmodule Comma.Auth.EmailRestriction do
  @moduledoc """
  Email addresses that can give one person any number of accounts: a domain
  in the excluded domain list (`priv/signup-credit-excluded-domains.json`, or
  `comma.billing.signup_credit_excluded_domains`), or a domain that receives
  its mail through Cloudflare Email Routing (an MX host under
  `mx.cloudflare.net`, where a catch-all address is free).

  A restricted address receives no registration or monthly free credits
  (`Comma.Billing.SignupCredits`, `Comma.Billing.FreeMonthlyCredits`), its
  Workspace starts no managed sandbox (`CommaWeb.Coding.SandboxAdmission`),
  and it signs in to no other service through the Comma OAuth/OIDC identity
  provider (`CommaWeb.OauthIdpConsent`, `Comma.OauthIdp.ResourceOwners`).
  It still signs in to Comma itself.

  The MX records are read from DNS each time. A domain without MX records,
  or one whose lookup fails or times out, is not counted as routed, so a
  resolver outage does not restrict other users.
  """

  @excluded_domains_path Path.expand("../../../priv/signup-credit-excluded-domains.json", __DIR__)
  @external_resource @excluded_domains_path
  @excluded_domains @excluded_domains_path |> File.read!() |> Jason.decode!()

  @routing_suffix ".mx.cloudflare.net"
  @lookup_opts [timeout: 2_000, retry: 1]

  @doc "Whether `email` is restricted: listed or on Cloudflare Email Routing."
  @spec restricted?(term()) :: boolean()
  def restricted?(email), do: listed?(email) or cloudflare_routed?(email)

  @doc "Whether the domain of `email` is in the excluded domain list. No DNS."
  @spec listed?(term()) :: boolean()
  def listed?(email) do
    case domain(email) do
      nil -> false
      domain -> listed_domain?(domain)
    end
  end

  @doc "Whether the domain of `email` receives mail through Cloudflare Email Routing."
  @spec cloudflare_routed?(term()) :: boolean()
  def cloudflare_routed?(email) do
    case domain(email) do
      nil -> false
      domain -> cloudflare_domain?(domain)
    end
  end

  @doc "Whether `domain` (lower case) is restricted. One MX lookup when not listed."
  @spec restricted_domain?(String.t()) :: boolean()
  def restricted_domain?(domain), do: listed_domain?(domain) or cloudflare_domain?(domain)

  defp listed_domain?(domain) do
    :comma_core
    |> SystemsRuntime.get_env(:signup_credit_excluded_domains, @excluded_domains)
    |> Enum.any?(fn
      "." <> base -> domain == base or String.ends_with?(domain, "." <> base)
      exact -> domain == exact
    end)
  end

  defp cloudflare_domain?(domain) do
    domain
    |> String.to_charlist()
    |> resolver().lookup(:in, :mx, @lookup_opts)
    |> Enum.any?(fn
      {_preference, host} -> host |> to_string() |> String.downcase() |> routed_host?()
      _ -> false
    end)
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp routed_host?(host),
    do: String.ends_with?(String.trim_trailing(host, "."), @routing_suffix)

  @doc false
  def domain(email) when is_binary(email) do
    case String.split(email, "@", parts: 2) do
      [_local, domain] when domain != "" -> String.downcase(domain)
      _ -> nil
    end
  end

  def domain(_email), do: nil

  # `:inet_res`, or a test's stand-in (SystemsRuntime.Test.NoDNS).
  defp resolver, do: SystemsRuntime.get_env(:comma_core, :mx_resolver, :inet_res)
end
