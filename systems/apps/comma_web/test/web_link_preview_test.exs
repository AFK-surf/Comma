defmodule CommaWeb.WebLinkPreviewTest do
  use SystemsClock.Case, async: false
  alias CommaWeb.WebLinkPreview

  defmodule Target do
    def public_http_target(url) do
      if URI.parse(url).host == "127.0.0.1" do
        {:error, :private}
      else
        {:ok, %{url: url, host_header: URI.parse(url).host, inet6: false, connect_options: []}}
      end
    end
  end

  setup do
    keys = [:web_link_preview_http_options, :web_link_preview_url_policy]
    previous = Map.new(keys, &{&1, SystemsRuntime.get_env(:comma_web, &1)})

    SystemsRuntime.put_env(:comma_web, :web_link_preview_http_options,
      plug: {Req.Test, __MODULE__}
    )

    SystemsRuntime.put_env(:comma_web, :web_link_preview_url_policy, Target)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> SystemsRuntime.delete_env(:comma_web, key)
        {key, value} -> SystemsRuntime.put_env(:comma_web, key, value)
      end)
    end)

    :ok
  end

  test "a public link reads OG title, description and relative raster media through the provider entrypoint" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert Plug.Conn.get_req_header(conn, "cookie") == []
      assert Plug.Conn.get_req_header(conn, "authorization") == []

      case conn.request_path do
        "/start" ->
          conn
          |> Plug.Conn.put_resp_header("location", "/products/server")
          |> Plug.Conn.send_resp(302, "")

        "/products/server" ->
          Req.Test.html(
            conn,
            ~s(<title>Fallback</title><meta property="og:title" content="B300 &amp; GPUs"><meta property="og:description" content="Eight GPUs"><meta property="og:image" content="../photo.png"><link rel="shortcut icon" href="/favicon.png">)
          )

        _ ->
          conn
          |> Plug.Conn.put_resp_content_type("image/png")
          |> Plug.Conn.send_resp(200, <<137, 80, 78, 71>>)
      end
    end)

    assert {:ok, preview} =
             CommaWeb.RecommendationLinkPreview.preview_connected(
               %{},
               "https://example.com/start",
               nil,
               "viewer"
             )

    assert preview["title"] == "B300 & GPUs"
    assert preview["description"] == "Eight GPUs"
    assert preview["siteName"] == "example.com"
    assert preview["image"] == "data:image/png;base64,iVBORw=="
    assert preview["icon"] == preview["image"]
    assert preview["href"] == "https://example.com/start"
  end

  test "plain HTML and Twitter metadata work without OG or an image" do
    Req.Test.stub(
      __MODULE__,
      &Req.Test.html(
        &1,
        ~s(<title>Plain title</title><meta name="description" content="Plain description">)
      )
    )

    assert {:ok,
            %{"title" => "Plain title", "description" => "Plain description", "image" => nil}} =
             WebLinkPreview.preview("https://example.com/")

    Req.Test.stub(
      __MODULE__,
      &Req.Test.html(&1, ~s(<meta name="twitter:title" content="Twitter title">))
    )

    assert {:ok, %{"title" => "Twitter title"}} = WebLinkPreview.preview("https://example.com/")
  end

  test "a page in a legacy charset gives no preview instead of invalid UTF-8" do
    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/html", "gbk")
      |> Plug.Conn.send_resp(200, "<title>" <> <<0xC4, 0xE3, 0xBA, 0xC3>> <> "</title>")
    end)

    assert WebLinkPreview.preview("https://example.com/") == {:error, :not_found}
  end

  test "obvious one-time links are never fetched, including redirects and media" do
    parent = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(parent, {:fetched, conn.request_path})

      case conn.request_path do
        "/redirect" ->
          conn
          |> Plug.Conn.put_resp_header("location", "/finish?access_token=secret")
          |> Plug.Conn.send_resp(302, "")

        _ ->
          Req.Test.html(
            conn,
            ~s(<title>Article</title><meta property="og:image" content="/image?token=secret"><link rel="icon" href="/unsubscribe/secret">)
          )
      end
    end)

    for path <- [
          "/?token=secret",
          "/?access%5Ftoken=secret",
          "/?TOKEN=secret&token=second",
          "/?code=secret",
          "/?mode=resetPassword",
          "/unsubscribe/secret",
          "/reset-password/secret",
          "/password/reset/secret",
          "/verify%2Demail/secret",
          "/magic-link/secret"
        ] do
      assert WebLinkPreview.preview("https://example.com" <> path) == {:error, :not_found}
    end

    refute_received {:fetched, _}
    assert WebLinkPreview.preview("https://example.com/redirect") == {:error, :not_found}
    assert_received {:fetched, "/redirect"}
    refute_received {:fetched, _}

    assert {:ok, %{"title" => "Article", "image" => nil, "icon" => nil}} =
             WebLinkPreview.preview("https://example.com/article?utm_source=mail&page=2")

    assert_received {:fetched, "/article"}
    refute_received {:fetched, _}
  end

  test "private targets, private services and redirects to them do not produce a preview" do
    for url <- [
          "file:///etc/passwd",
          "https://user:password@example.com",
          "http://127.0.0.1",
          "https://mail.google.com/mail",
          "https://team.slack.com/archives/C123"
        ] do
      assert WebLinkPreview.preview(url) == {:error, :not_found}
    end

    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.host == "example.com"

      conn
      |> Plug.Conn.put_resp_header("location", "http://127.0.0.1/private")
      |> Plug.Conn.send_resp(302, "")
    end)

    assert WebLinkPreview.preview("https://example.com/") == {:error, :not_found}
  end

  test "oversized pages and redirect loops stop; bad images do not discard metadata" do
    Req.Test.stub(__MODULE__, &Req.Test.html(&1, String.duplicate("x", 1_048_577)))
    assert WebLinkPreview.preview("https://example.com/") == {:error, :not_found}

    Req.Test.stub(__MODULE__, fn conn ->
      conn |> Plug.Conn.put_resp_header("location", "/loop") |> Plug.Conn.send_resp(302, "")
    end)

    assert WebLinkPreview.preview("https://example.com/") == {:error, :not_found}

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/" ->
          Req.Test.html(
            conn,
            ~s(<title>Still readable</title><meta property="og:image" content="/image">)
          )

        "/image" ->
          conn
          |> Plug.Conn.put_resp_content_type("image/svg+xml")
          |> Plug.Conn.send_resp(200, "<svg/>")
      end
    end)

    assert {:ok, %{"title" => "Still readable", "image" => nil}} =
             WebLinkPreview.preview("https://example.com/")
  end
end
