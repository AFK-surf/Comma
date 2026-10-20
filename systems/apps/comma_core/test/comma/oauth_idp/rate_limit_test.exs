defmodule Comma.OauthIdp.RateLimitTest do
  # async: false — policies live in application config.
  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle, scope: ["Elixir.Comma"]
  alias Comma.OauthIdp.RateLimit

  setup do
    previous = SystemsRuntime.get_env(:comma_core, :oauth_idp_rate_limit)

    on_exit(fn ->
      case previous do
        nil -> SystemsRuntime.delete_env(:comma_core, :oauth_idp_rate_limit)
        value -> SystemsRuntime.put_env(:comma_core, :oauth_idp_rate_limit, value)
      end
    end)

    :ok
  end

  defp set_policy(endpoint, burst, rate) do
    SystemsRuntime.put_env(:comma_core, :oauth_idp_rate_limit, [
      {endpoint, [burst: burst, rate: rate]}
    ])
  end

  defp unique_peer, do: {:peer, SystemsRuntime.Proc.make_ref()}

  test "allows up to burst then denies with a positive retry-after" do
    set_policy(:token, 3, 0.0)
    peer = unique_peer()

    assert :allow = RateLimit.check(:token, peer)
    assert :allow = RateLimit.check(:token, peer)
    assert :allow = RateLimit.check(:token, peer)
    assert {:deny, retry_after} = RateLimit.check(:token, peer)
    assert retry_after >= 1
  end
end
