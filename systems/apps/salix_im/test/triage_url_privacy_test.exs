defmodule SalixIM.Triage.URLPrivacyTest do
  use ExUnit.Case, async: true

  alias SalixIM.Triage.URLPrivacy

  test "canonicalizes HTTPS host case, trailing dot, default port, and empty path" do
    assert {:ok, "https://docs.example.test/triage"} =
             URLPrivacy.canonical_https_url("https://DOCS.EXAMPLE.TEST.:443/triage")

    assert {:ok, "https://docs.example.test/"} =
             URLPrivacy.canonical_https_url("HTTPS://Docs.Example.Test:443")
  end

  test "redacts ordinary, Slack-named, and redirect-result URLs structurally" do
    text =
      "requested https://DOCS.EXAMPLE.TEST.:443/triage; " <>
        "Slack rendered <https://docs.example.test/triage|spec>; " <>
        "redirected to https://cdn.example.test/final."

    redacted = URLPrivacy.redact_https_urls(text, "link://run/l001")

    refute URLPrivacy.contains_https_url?(redacted)
    assert redacted =~ "Slack rendered <link://run/l001|spec>"
    assert redacted =~ "redirected to link://run/l001."
  end

  # A bare scheme with nothing after it is not a URL. Extracting it as one and
  # then globally replacing that string stripped `https://` off every OTHER URL
  # in the same text, leaving its host and path standing in the clear.
  test "a scheme with no host never becomes an alias that shadows a real URL" do
    text = "broken https://). and real https://internal.corp/secret?t=abc"

    assert URLPrivacy.extract_https_urls(text) == ["https://internal.corp/secret?t=abc"]

    redacted = URLPrivacy.redact_https_urls(text, "link://run/l001")

    refute redacted =~ "internal.corp"
    refute redacted =~ "secret"
    assert redacted =~ "link://run/l001"
    # Nothing scheme-shaped survives, so the fail-closed verifier passes.
    refute URLPrivacy.residual_https_scheme?(redacted)
  end

  # `https://x.test` is a prefix of `https://x.test/secret`. Replacing the short
  # one first consumed that prefix and left the path standing after the alias.
  test "a longer URL is redacted before the shorter one it extends" do
    text = "Slack rendered <https://x.test|home> and the raw https://x.test/secret"

    redacted = URLPrivacy.redact_https_urls(text, "link://run/l001")

    refute redacted =~ "/secret"
    refute redacted =~ "x.test"
    assert redacted == "Slack rendered <link://run/l001|home> and the raw link://run/l001"
    refute URLPrivacy.residual_https_scheme?(redacted)
  end

  test "distinct URLs can carry distinct aliases" do
    text = "primary https://a.test/one and other https://b.test/two"

    redacted =
      URLPrivacy.redact_https_urls(text, fn
        "https://a.test/one" -> "link://run/l001"
        _other -> "link://page/l002"
      end)

    assert redacted == "primary link://run/l001 and other link://page/l002"
  end

  test "the fail-closed verifier answers on the substring, not on the parse" do
    assert URLPrivacy.residual_https_scheme?("nothing to see https://")
    refute URLPrivacy.contains_https_url?("nothing to see https://")
    assert URLPrivacy.residual_https_scheme?(:not_a_binary)
  end
end
