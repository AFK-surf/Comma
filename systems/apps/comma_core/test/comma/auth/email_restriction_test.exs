defmodule Comma.Auth.EmailRestrictionTest do
  use ExUnit.Case, async: true

  alias Comma.Auth.EmailRestriction
  alias Comma.TestSupport.MxRecords

  defmodule Failing do
    def lookup(_name, _class, _type, _opts), do: raise("resolver down")
  end

  test "a domain whose mail goes through Cloudflare Email Routing is restricted" do
    MxRecords.put(%{
      "catchall.test" => ["route1.mx.cloudflare.net.", "route2.MX.cloudflare.net"],
      "mixed.test" => ["mx.mixed.test", "route3.mx.cloudflare.net"],
      "mail.test" => ["mx1.mail.test"]
    })

    assert EmailRestriction.restricted?("someone@CatchAll.test")
    assert EmailRestriction.cloudflare_routed?("someone@catchall.test")
    assert EmailRestriction.restricted?("someone@mixed.test")
    refute EmailRestriction.restricted?("someone@mail.test")
    refute EmailRestriction.restricted?("someone@no-mx.test")
    refute EmailRestriction.restricted?("not-an-email")
  end

  test "a listed domain is restricted without a lookup" do
    SystemsRuntime.Test.put_env(:comma_core, :mx_resolver, Failing)

    assert EmailRestriction.listed?("someone@0r9.org")
    assert EmailRestriction.restricted?("someone@outlook.com")
    assert EmailRestriction.restricted?("someone@sub.mozmail.com")
  end

  test "a lookup that fails restricts nobody" do
    SystemsRuntime.Test.put_env(:comma_core, :mx_resolver, Failing)

    refute EmailRestriction.restricted?("someone@mail.test")
  end
end
