defmodule SalixSignal.Service.HttpAndChallengeTest do
  # Plain HTTPS requests with pinned roots (CRS-01 sections 3 and 4) and
  # challenge answers (CRS-01 section 13) against the fake chat service.
  use SystemsClock.Case, async: true

  alias SalixSignal.Service.{Challenge, Chat, Credentials, Http, Response}
  alias SalixSignal.Test.FakeChat
  alias SalixSignalProto.Service.Frame
  setup_all do
    %{chain: FakeChat.chain()}
  end

  setup %{chain: chain} do
    {:ok, upgrades} = Agent.start_link(fn -> [] end)

    server =
      start_supervised!(
        {Bandit, FakeChat.bandit_options(SystemsRuntime.Proc.self(), chain, upgrades)}
      )

    %{port: FakeChat.port(server)}
  end

  test "HTTPS requests trust only the given roots and send Basic credentials", context do
    url = "https://localhost:#{context.port}/v1/storage/auth"
    credentials = Credentials.registration("+15555550123", "example-password")

    assert {:ok, %Response{status: 200, body: body} = response} =
             Http.request(:get, url, credentials: credentials, roots: [context.chain.root])

    assert body == Credentials.authorization(credentials)
    assert Response.server_time_ms(response) == 1_758_790_000_000

    other = FakeChat.chain()
    assert {:error, %{reason: {:tls_alert, _}}} = Http.request(:get, url, roots: [other.root])
  end
end
