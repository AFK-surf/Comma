defmodule CommaWeb.WebLinkPreview do
  @moduledoc false

  # Public pages only: no browser cookies, provider credentials or script execution.
  # Req and Floki own HTTP and HTML parsing. URLPolicy pins every redirect and
  # image request to a public address, as it does for link-preview avatars.
  @max_html_bytes 1_048_576
  @max_image_bytes 262_144
  @timeout 3_000
  @image_types ~w(image/png image/jpeg image/webp image/gif image/x-icon image/vnd.microsoft.icon)

  def preview(href) do
    with true <- public_page?(href),
         {:ok, response, final_url} <- fetch(href, @max_html_bytes, 3),
         true <- media_type(response) in ["text/html", "application/xhtml+xml"],
         {:ok, document} <- Floki.parse_document(response.body),
         title when is_binary(title) <-
           meta(document, ["og:title", "twitter:title"]) ||
             text(document, "title", 300) do
      {:ok,
       %{
         "kind" => "web_page",
         "href" => href,
         "title" => title,
         "description" =>
           meta(document, ["og:description", "twitter:description", "description"]),
         "siteName" => meta(document, ["og:site_name"]) || URI.parse(final_url).host,
         "image" => image(meta(document, ["og:image", "twitter:image"]), final_url),
         "icon" => image(icon(document), final_url)
       }}
    else
      _ -> {:error, :not_found}
    end
  rescue
    _ -> {:error, :not_found}
  end

  # Private mail/calendar/document services retain their provider read path;
  # a failed authorization must never turn into an anonymous website fetch.
  def public_page?(href) when is_binary(href) and byte_size(href) <= 2_048 do
    uri = URI.parse(href)
    host = String.downcase(uri.host || "")

    String.valid?(href) and uri.scheme in ["http", "https"] and host != "" and
      is_nil(uri.userinfo) and
      uri.port in [80, 443] and
      not one_time_link?(uri) and
      not Enum.any?(
        ~w(slack.com notion.so notion.site linear.app still.fail app.youdid.wtf),
        fn domain ->
          host == domain or String.ends_with?(host, "." <> domain)
        end
      ) and
      host not in ~w(mail.google.com calendar.google.com docs.google.com drive.google.com outlook.office.com outlook.office365.com outlook.live.com) and
      not (host == "www.google.com" and String.starts_with?(uri.path || "", "/calendar"))
  end

  def public_page?(_), do: false

  # Hover must not consume obvious credentials or trigger account actions.
  # Apply this to every fetch, including redirects and metadata image URLs.
  # This is a conservative heuristic, not a guarantee that arbitrary GETs are inert.
  defp one_time_link?(uri) do
    normalize = fn value ->
      value |> URI.decode() |> String.downcase() |> String.replace(~r/[^a-z0-9]/, "")
    end

    actions =
      ~w(unsubscribe signout logout magiclink magiclogin resetpassword passwordreset verifyemail emailverify confirmemail emailconfirmation activateaccount acceptinvite)

    segments =
      (uri.path || "")
      |> URI.decode()
      |> String.split("/", trim: true)
      |> Enum.map(normalize)

    path_action? =
      (segments ++ Enum.map(Enum.chunk_every(segments, 2, 1, :discard), &Enum.join/1))
      |> Enum.any?(&(&1 in actions))

    query_action? =
      URI.query_decoder(uri.query || "")
      |> Enum.any?(fn {key, value} ->
        key = normalize.(key)

        String.contains?(key, "token") or
          key in ~w(code otp ticket signature sig credential authorization auth key secret) or
          key in actions or
          (key in ~w(action mode operation) and normalize.(value) in actions)
      end)

    path_action? or query_action?
  rescue
    _ -> true
  end

  defp fetch(url, limit, redirects) do
    with true <- public_page?(url),
         {:ok, target} <- url_policy().public_http_target(url),
         {:ok, response} <- Req.request(options(target, limit)) do
      cond do
        response.status == 200 and is_binary(response.body) and byte_size(response.body) <= limit ->
          {:ok, response, url}

        response.status in [301, 302, 303, 307, 308] and redirects > 0 ->
          case Req.Response.get_header(response, "location") do
            [location | _] ->
              fetch(URI.merge(url, location) |> URI.to_string(), limit, redirects - 1)

            _ ->
              {:error, :not_found}
          end

        true ->
          {:error, :not_found}
      end
    else
      _ -> {:error, :not_found}
    end
  end

  defp options(target, limit) do
    Keyword.merge(
      [
        method: :get,
        url: target.url,
        headers: %{
          "host" => target.host_header,
          "user-agent" => "Comma-LinkPreview",
          "accept" => "text/html, image/*"
        },
        connect_options: Keyword.put(target.connect_options, :timeout, @timeout),
        inet6: target.inet6,
        redirect: false,
        retry: false,
        decode_body: false,
        receive_timeout: @timeout,
        pool_timeout: @timeout,
        into: fn {:data, data}, {request, response} ->
          body = if is_binary(response.body), do: response.body <> data, else: data

          if byte_size(body) > limit,
            do: {:halt, {request, %{response | body: :too_large}}},
            else: {:cont, {request, %{response | body: body}}}
        end
      ],
      SystemsRuntime.get_env(:comma_web, :web_link_preview_http_options, [])
    )
  end

  # Bounded raster data travels with the preview so web and desktop can render
  # it without sending the reader's IP/cookies to another site. SVG is excluded.
  defp image(nil, _base), do: nil

  defp image(value, base) do
    url = URI.merge(base, value) |> URI.to_string()

    with {:ok, response, _} <- fetch(url, @max_image_bytes, 2),
         type when type in @image_types <- media_type(response),
         true <- response.body != "" do
      "data:" <> type <> ";base64," <> Base.encode64(response.body)
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp meta(document, names) do
    Enum.find_value(names, fn name ->
      document
      |> Floki.find("meta")
      |> Enum.find_value(fn {_, attributes, _} ->
        attrs = Map.new(attributes)

        if String.downcase(attrs["property"] || attrs["name"] || "") == name,
          do: clean(attrs["content"], 1_000)
      end)
    end)
  end

  defp text(document, selector, limit),
    do: document |> Floki.find(selector) |> Floki.text() |> clean(limit)

  defp clean(nil, _limit), do: nil

  defp clean(value, limit) do
    # Legacy charsets (GBK, Shift_JIS, Latin-1) are not decoded; JSON needs UTF-8.
    if String.valid?(value), do: trim(value, limit)
  end

  defp trim(value, limit) do
    case value |> String.trim() |> String.slice(0, limit) do
      "" -> nil
      value -> value
    end
  end

  defp icon(document) do
    document
    |> Floki.find("link")
    |> Enum.find_value(fn {_, attributes, _} ->
      attrs = Map.new(attributes)
      if "icon" in String.split(String.downcase(attrs["rel"] || "")), do: attrs["href"]
    end)
  end

  defp media_type(response) do
    response
    |> Req.Response.get_header("content-type")
    |> List.first("")
    |> String.split(";", parts: 2)
    |> hd()
    |> String.trim()
    |> String.downcase()
  end

  defp url_policy,
    do: SystemsRuntime.get_env(:comma_web, :web_link_preview_url_policy, SalixMCP.URLPolicy)
end
