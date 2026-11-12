defmodule CommaWeb.LinkPreviewAvatarTest do
  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle, scope: ["Elixir.CommaWeb", "Elixir.Comma"]
  alias CommaWeb.LinkPreviewAvatar

  @github_avatar "https://avatars.githubusercontent.com/u/1?v=4"
  @png <<137, 80, 78, 71, 13, 10, 26, 10>>

  defmodule PinnedTarget do
    @moduledoc "A URL policy that admits every URL, as the real one does a public host."
    def public_http_target(url) do
      {:ok,
       %{
         url: url,
         connect_options: [hostname: URI.parse(url).host],
         host_header: URI.parse(url).host,
         inet6: false
       }}
    end
  end

  defmodule BlockedTarget do
    @moduledoc "A URL policy that admits nothing, as the real one does a host on a private address."
    def public_http_target(_url), do: {:error, {:bad_request, "host is not allowed"}}
  end

  setup do
    keys = [:link_preview_avatar_http_options, :link_preview_avatar_url_policy]
    previous = Map.new(keys, &{&1, SystemsRuntime.get_env(:comma_web, &1)})

    SystemsRuntime.put_env(:comma_web, :link_preview_avatar_http_options,
      plug: {Req.Test, __MODULE__}
    )

    SystemsRuntime.put_env(:comma_web, :link_preview_avatar_url_policy, PinnedTarget)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> SystemsRuntime.delete_env(:comma_web, key)
        {key, value} -> SystemsRuntime.put_env(:comma_web, key, value)
      end)
    end)

    :ok
  end

  describe "ref/1 and url/1" do
    test "a provider's avatar URL gets a reference that names it again" do
      ref = LinkPreviewAvatar.ref(@github_avatar)
      assert is_binary(ref)
      assert LinkPreviewAvatar.url(ref) == {:ok, @github_avatar}

      for url <- [
            "https://public-files.linear.app/avatar.png",
            "https://avatars.slack-edge.com/2026-10-01/U1_72.jpg",
            "https://lh3.googleusercontent.com/a/photo=s64"
          ] do
        assert LinkPreviewAvatar.url(LinkPreviewAvatar.ref(url)) == {:ok, url}
      end
    end

    test "no reference for a URL Comma does not read" do
      assert LinkPreviewAvatar.ref(nil) == nil
      assert LinkPreviewAvatar.ref("") == nil
      assert LinkPreviewAvatar.ref("http://avatars.githubusercontent.com/u/1") == nil
      assert LinkPreviewAvatar.ref("https://example.com/avatar.png") == nil

      assert LinkPreviewAvatar.ref("https://evil.avatars.githubusercontent.com.example/u/1") ==
               nil

      assert LinkPreviewAvatar.ref("https://user:pass@avatars.githubusercontent.com/u/1") == nil
      assert LinkPreviewAvatar.ref("https://avatars.githubusercontent.com:8443/u/1") == nil

      assert LinkPreviewAvatar.ref(
               "https://avatars.githubusercontent.com/" <> String.duplicate("a", 2_048)
             ) == nil
    end

    test "a reference this server did not sign names nothing" do
      ref = LinkPreviewAvatar.ref(@github_avatar)
      ["v1", encoded, signature] = String.split(ref, ".")

      other = Base.url_encode64("https://avatars.githubusercontent.com/u/2", padding: false)
      assert LinkPreviewAvatar.url("v1." <> other <> "." <> signature) == :error

      assert LinkPreviewAvatar.url("v1." <> encoded <> "." <> String.slice(signature, 1..-1//1)) ==
               :error

      assert LinkPreviewAvatar.url("v1." <> encoded) == :error
      assert LinkPreviewAvatar.url("v2." <> encoded <> "." <> signature) == :error
      assert LinkPreviewAvatar.url("") == :error
    end
  end

  describe "fetch/1" do
    test "answers a bounded image from the pinned public target, without following a redirect" do
      ref = LinkPreviewAvatar.ref(@github_avatar)

      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.host == "avatars.githubusercontent.com"
        assert conn.request_path == "/u/1"
        assert conn.query_string == "v=4"
        conn |> Plug.Conn.put_resp_content_type("image/png") |> Plug.Conn.send_resp(200, @png)
      end)

      assert LinkPreviewAvatar.fetch(ref) == {:ok, "image/png", @png}

      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "https://example.com/x")
        |> Plug.Conn.send_resp(302, "")
      end)

      assert LinkPreviewAvatar.fetch(ref) == {:error, :not_found}

      Req.Test.stub(__MODULE__, fn conn ->
        conn |> Plug.Conn.put_resp_content_type("text/html") |> Plug.Conn.send_resp(200, "<html>")
      end)

      assert LinkPreviewAvatar.fetch(ref) == {:error, :not_found}

      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("image/png")
        |> Plug.Conn.send_resp(200, :binary.copy(<<0>>, 1_048_577))
      end)

      assert LinkPreviewAvatar.fetch(ref) == {:error, :not_found}

      Req.Test.stub(__MODULE__, fn conn ->
        conn |> Plug.Conn.put_resp_content_type("image/png") |> Plug.Conn.send_resp(404, "")
      end)

      assert LinkPreviewAvatar.fetch(ref) == {:error, :not_found}
    end

    test "a host the policy does not resolve to a public address is never requested" do
      SystemsRuntime.put_env(:comma_web, :link_preview_avatar_url_policy, BlockedTarget)
      Req.Test.stub(__MODULE__, fn _conn -> flunk("a blocked host must not be requested") end)

      assert LinkPreviewAvatar.fetch(LinkPreviewAvatar.ref(@github_avatar)) ==
               {:error, :not_found}
    end

    test "an unsigned reference is never requested" do
      Req.Test.stub(__MODULE__, fn _conn ->
        flunk("an unsigned reference must not be requested")
      end)

      encoded = Base.url_encode64("https://avatars.githubusercontent.com/u/1", padding: false)
      assert LinkPreviewAvatar.fetch("v1." <> encoded <> ".bad") == {:error, :not_found}
      assert LinkPreviewAvatar.fetch("avt_x") == {:error, :not_found}
    end
  end
end
