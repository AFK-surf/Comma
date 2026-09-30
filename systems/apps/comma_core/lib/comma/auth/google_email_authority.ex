defmodule Comma.Auth.GoogleEmailAuthority do
  @moduledoc "Fail-closed first-link classifier for Google-provided email claims."

  alias Comma.Auth.GoogleClaims

  @google_mail_domains MapSet.new(["gmail.com", "googlemail.com"])

  @spec classify(GoogleClaims.t() | term()) :: :authoritative | :requires_otp
  def classify(%GoogleClaims{email: email, email_verified: true} = claims)
      when is_binary(email) do
    with [_, domain] <- String.split(email, "@", parts: 2),
         true <- domain != "" do
      if MapSet.member?(@google_mail_domains, domain) or claims.hosted_domain == domain,
        do: :authoritative,
        else: :requires_otp
    else
      _other -> :requires_otp
    end
  rescue
    _exception -> :requires_otp
  catch
    _kind, _reason -> :requires_otp
  end

  def classify(_claims), do: :requires_otp
end
