defmodule SalixSignal.Service.HttpAndChallengeTest do
  # Plain HTTPS requests with pinned roots (CRS-01 sections 3 and 4) and
  # challenge answers (CRS-01 section 13) against the fake chat service.
  use ExUnit.Case, async: true

  alias SalixSignal.Service.{Challenge, Chat, Credentials, Http, Response}
  alias SalixSignal.Test.FakeChat
  alias SalixSignalProto.Service.Frame

  # Upper bounds on a loaded machine: a TLS connect and upgrade (the
  # client's own connect timeout is 10 s), and a challenge answer.
  @connect_ms 30_000
  @answer_ms 30_000

  setup_all do
    %{chain: FakeChat.chain()}
  end

  setup %{chain: chain} do
    {:ok, upgrades} = Agent.start_link(fn -> [] end)
    server = start_supervised!({Bandit, FakeChat.bandit_options(self(), chain, upgrades)})
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

  test "a captcha answer is retried after 503, not after 508", context do
    chat =
      start_supervised!(
        {Chat,
         owner: self(),
         host: "localhost",
         port: context.port,
         roots: [context.chain.root],
         credentials: Credentials.device("3f0f4b1c-5d2e-4a6b-8c7d-9e0f1a2b3c4d", 1, "pw")}
      )

    assert_receive {:signal_chat, ^chat, {:connected, _}}, @connect_ms
    assert_receive {:fake_chat, :connected, socket}, @connect_ms

    answer = Challenge.captcha_answer("t-1", "signalcaptcha://signal-hcaptcha.K.challenge.S")

    submit = fn -> Task.async(fn -> Challenge.submit(chat, answer, backoff: [base_ms: 1]) end) end

    task = submit.()

    assert_receive {:fake_chat, :frame, ^socket,
                    %Frame.Request{verb: "PUT", path: "/v1/challenge"} = put}

    assert Jason.decode!(put.body) == %{
             "type" => "captcha",
             "token" => "t-1",
             "captcha" => "signal-hcaptcha.K.challenge.S"
           }

    send(socket, {:send, Frame.encode_response(%Frame.Response{id: put.id, status: 503})})
    assert_receive {:fake_chat, :frame, ^socket, %Frame.Request{path: "/v1/challenge"} = retry}
    send(socket, {:send, Frame.encode_response(%Frame.Response{id: retry.id, status: 200})})
    assert Task.await(task, @answer_ms) == :ok

    task = submit.()
    assert_receive {:fake_chat, :frame, ^socket, %Frame.Request{path: "/v1/challenge"} = put}
    send(socket, {:send, Frame.encode_response(%Frame.Response{id: put.id, status: 508})})
    assert Task.await(task, @answer_ms) == {:error, :rejected}
    refute_receive {:fake_chat, :frame, ^socket, %Frame.Request{path: "/v1/challenge"}}, 100
  end
end
