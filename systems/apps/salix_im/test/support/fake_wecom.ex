defmodule SalixIM.TestSupport.FakeWeCom do
  @moduledoc """
  A fake of WeCom's AI bot long connection (`wss://openws.work.weixin.qq.com`)
  and of the storage it serves attachments from. It answers what the official
  SDKs expect: `errcode` 0 for a subscription with `secret/0`, a ping, a send
  or an upload step, with the request's own `req_id`, and it forwards every
  frame to the test as `{:fake_wecom, :frame, frame}`. `refuse_replies: true`
  in the behavior agent makes it refuse `aibot_respond_msg`, and
  `hold_replies: true` makes it leave them unanswered. A file put in the
  media agent under a name is served at `/media/<name>`.
  """

  alias SalixIM.TestSupport.BanditServer

  @doc "The Secret the fake takes."
  def secret, do: "fake-wecom-secret-0123456789abcdef"

  @doc "Serves the fake for `test`; returns its HTTP base, its socket URL and its agents."
  def serve!(test) do
    {:ok, behavior} = Agent.start_link(fn -> %{} end)
    {:ok, media} = Agent.start_link(fn -> %{} end)
    base = BanditServer.serve!(__MODULE__.Plug, %{test: test, behavior: behavior, media: media})

    %{
      base: base,
      url: String.replace(base, "http://", "ws://"),
      behavior: behavior,
      media: media
    }
  end

  defmodule Plug do
    @moduledoc false
    import Elixir.Plug.Conn

    def init(opts), do: opts

    def call(%{request_path: "/media/" <> name} = conn, %{media: media}) do
      case Agent.get(media, &Map.get(&1, name)) do
        nil ->
          send_resp(conn, 404, "")

        bytes ->
          conn
          |> put_resp_header("content-disposition", "attachment; filename=%E6%B7%98%E5%AE%9D.png")
          |> send_resp(200, bytes)
      end
    end

    def call(conn, opts) do
      conn
      |> WebSockAdapter.upgrade(SalixIM.TestSupport.FakeWeCom.Socket, opts, [])
      |> halt()
    end
  end

  defmodule Socket do
    @moduledoc false
    @behaviour WebSock

    @impl true
    def init(%{test: test} = state) do
      SystemsRuntime.Proc.send(test, {:fake_wecom, :socket, SystemsRuntime.Proc.self()})
      {:ok, state}
    end

    @impl true
    def handle_in({text, opcode: :text}, %{test: test} = state) do
      frame = Jason.decode!(text)
      SystemsRuntime.Proc.send(test, {:fake_wecom, :frame, frame})

      if frame["cmd"] == "aibot_respond_msg" and
           Agent.get(state.behavior, & &1[:hold_replies]),
         do: {:ok, state},
         else: {:push, {:text, Jason.encode!(answer(frame, state))}, state}
    end

    def handle_in(_other, state), do: {:ok, state}

    @impl true
    def handle_info({:send, frame}, state), do: {:push, {:text, Jason.encode!(frame)}, state}
    def handle_info(_message, state), do: {:ok, state}

    defp answer(%{"cmd" => "aibot_subscribe", "headers" => headers, "body" => body}, _state) do
      if body["secret"] == SalixIM.TestSupport.FakeWeCom.secret(),
        do: ok(headers),
        else: %{
          "headers" => headers,
          "errcode" => 853_000,
          "errmsg" => "invalid bot_id or secret"
        }
    end

    defp answer(%{"cmd" => "aibot_respond_msg", "headers" => headers}, %{behavior: behavior}) do
      if Agent.get(behavior, & &1[:refuse_replies]),
        do: %{"headers" => headers, "errcode" => 846_605, "errmsg" => "reply expired"},
        else: ok(headers)
    end

    defp answer(%{"cmd" => "aibot_upload_media_init", "headers" => headers}, _state),
      do: Map.put(ok(headers), "body", %{"upload_id" => "up_1"})

    defp answer(%{"cmd" => "aibot_upload_media_finish", "headers" => headers}, _state),
      do: Map.put(ok(headers), "body", %{"type" => "file", "media_id" => "media_1"})

    defp answer(%{"headers" => headers}, _state), do: ok(headers)

    defp ok(headers), do: %{"headers" => headers, "errcode" => 0, "errmsg" => "ok"}
  end
end
