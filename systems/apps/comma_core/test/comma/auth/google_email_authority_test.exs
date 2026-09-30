defmodule Comma.Auth.GoogleEmailAuthorityTest do
  use ExUnit.Case, async: true

  alias Comma.Auth.{GoogleClaims, GoogleEmailAuthority}

  test "only verified Gmail, Googlemail, or exact Workspace hd is authoritative" do
    for {email, hd} <- [
          {"peng@gmail.com", nil},
          {"peng@googlemail.com", nil},
          {"peng@example.com", "example.com"}
        ] do
      assert :authoritative ==
               GoogleEmailAuthority.classify(claims(email, true, hd))
    end
  end

  test "all uncertain or non-authoritative branches fail closed to OTP" do
    cases = [
      claims("peng@gmail.com", false, nil),
      claims("peng@gmail.com", :invalid, nil),
      claims("peng@example.com", true, nil),
      claims("peng@example.com", true, "other.example"),
      claims("peng@example.com", true, "login.example.com"),
      claims("peng@login.example.com", true, "example.com"),
      claims("peng@example.com", true, :invalid),
      claims(nil, true, "example.com"),
      %GoogleClaims{
        issuer: "https://accounts.google.com",
        subject: "subject",
        email: "peng@gmail.com.evil.test",
        email_verified: true,
        hosted_domain: nil
      },
      %{},
      nil
    ]

    assert Enum.all?(cases, &(GoogleEmailAuthority.classify(&1) == :requires_otp))
  end

  defp claims(email, verified, hosted_domain) do
    %GoogleClaims{
      issuer: "https://accounts.google.com",
      subject: "subject",
      email: email,
      email_verified: verified,
      hosted_domain: hosted_domain
    }
  end
end
