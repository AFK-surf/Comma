defmodule SalixIM.Triage.URLPrivacyTest do
  use SystemsClock.Case, async: true

  alias SalixIM.Triage.URLPrivacy

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

  test "the fail-closed verifier answers on the substring, not on the parse" do
    assert URLPrivacy.residual_https_scheme?("nothing to see https://")
    refute URLPrivacy.contains_https_url?("nothing to see https://")
    assert URLPrivacy.residual_https_scheme?(:not_a_binary)
  end
end
