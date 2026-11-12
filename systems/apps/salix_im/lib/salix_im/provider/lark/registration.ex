defmodule SalixIM.Provider.Lark.Registration do
  @moduledoc """
  One-click app creation on the Lark and Feishu open platforms.

  The platforms make a custom app with a bot through an OAuth device flow
  (RFC 8628), as their SDKs' `register_app` does:

    1. `begin/2` asks for a device code and gives the link a person opens
       in Lark or Feishu, or scans as a QR code. The link names the app and
       asks for the scopes, events and callbacks a connect needs (`addons`).
       A registration always begins on Feishu's accounts service; the
       platform only picks the page the person confirms on (`/page/cli`,
       as Lark's own CLI does: Lark's `/page/launcher` makes the app but
       never answers the poll).
    2. The person confirms in Lark or Feishu. The platform creates and
       publishes the app with the bot capability, and its events come
       through the long connection (`SalixIM.LarkSocket`).
    3. `poll/2` asks once whether the app exists. When it does, the answer
       carries its App ID, App Secret and the creator's open_id.

  The device code is a credential: whoever holds it gets the App Secret. A
  caller that hands it to a browser seals it first.

  The same flow updates an app made before (`begin/3` with `app_id:`), as
  the SDKs' `register_app` with `appId` does: the person confirms the scopes
  `addons` adds to the app, and the poll answers that app. An app made by a
  scan has nobody in the Developer Console, so this is how it gets a scope a
  connect needs since it was made.

  The poll says `tenant_brand: "lark"` for a Lark tenant, and the code is
  asked on Lark from then on (`domain` of the answer). Asked again, it answers
  the same app.
  """

  @endpoint "/oauth/v1/app/registration"
  @accounts %{
    "lark" => "https://accounts.larksuite.com",
    "feishu" => "https://accounts.feishu.cn"
  }
  @pages %{
    "lark" => "https://open.larksuite.com/page/cli",
    "feishu" => "https://open.feishu.cn/page/cli"
  }

  # What the member's own sign-in with the app reads for their Routine
  # (`CommaWeb.RecommendationLarkMemberSource`): messages that mention them
  # and their direct messages, the chats those are in, and calendar events
  # that wait for their answer. The names are the platform's user scopes, as
  # the official larksuite/cli asks for them.
  @member_scopes [
    "search:message",
    "im:message.group_msg:get_as_user",
    "im:message.p2p_msg:get_as_user",
    "im:chat:read",
    "calendar:calendar.event:read"
  ]

  # What a connect needs of its app (`SalixIM.LarkInbound`,
  # `BridgeForTeams.LarkScopes`): receive and send messages, read its chats
  # and their members, join public groups, resolve people, answer card buttons,
  # and join the Lark video meetings a person invites the bot to.
  @addons %{
    "scopes" => %{
      "tenant" => [
        "im:message",
        "im:message:send_as_bot",
        "im:message.group_msg",
        "im:message.p2p_msg:readonly",
        "im:message.group_at_msg:readonly",
        "im:resource",
        "im:chat:readonly",
        "im:chat.members:read",
        "im:chat.members:write_only",
        "contact:user.base:readonly",
        "contact:user.id:readonly",
        "cardkit:card:write",
        "tenant:tenant:readonly",
        "vc:meeting.bot.join:write",
        "vc:meeting.message:write"
      ],
      # The member's own sign-in with the app (`member_scopes/0`).
      "user" => @member_scopes
    },
    "events" => %{
      "items" => %{
        "tenant" => [
          "im.message.receive_v1",
          "im.message.recalled_v1",
          "im.chat.member.bot.added_v1",
          "vc.bot.meeting_invited_v1",
          "vc.bot.meeting_ended_v1"
        ]
      }
    },
    "callbacks" => %{"items" => ["card.action.trigger"]}
  }

  @type domain :: String.t()
  @type begun :: %{
          device_code: String.t(),
          url: String.t(),
          interval_s: pos_integer(),
          expires_in_s: pos_integer(),
          domain: domain()
        }
  @type app :: %{
          app_id: String.t(),
          app_secret: String.t(),
          open_id: String.t() | nil,
          brand: String.t() | nil,
          domain: domain()
        }

  @doc "The user scopes a member's own sign-in with a scanned app asks for."
  def member_scopes, do: @member_scopes

  @doc "The platforms a registration can begin on."
  def domains, do: Map.keys(@accounts)

  @doc """
  Begins one registration whose link is confirmed on `domain`'s page
  (`"lark"` or `"feishu"`). `name` is the app's suggested name. With
  `app_id:` it updates that app instead of making one. The poll starts on
  Feishu (`domain` of the answer).
  """
  @spec begin(domain(), String.t(), keyword()) :: {:ok, begun()} | {:error, String.t()}
  def begin(domain, name, opts \\ [])

  def begin(domain, name, opts) when is_map_key(@accounts, domain) and is_binary(name) do
    with {:ok, init} <- post("feishu", %{"action" => "init"}),
         :ok <- client_secret_offered(init),
         {:ok, begun} <-
           post("feishu", %{
             "action" => "begin",
             "archetype" => "PersonalAgent",
             "auth_method" => "client_secret",
             "request_user_info" => "open_id tenant_brand"
           }),
         {:ok, device_code, user_code} <- device_code(begun) do
      {:ok,
       %{
         device_code: device_code,
         url: link(@pages[domain], user_code, name, opts[:app_id]),
         interval_s: positive(begun["interval"], 5),
         expires_in_s: positive(begun["expire_in"] || begun["expires_in"], 600),
         domain: "feishu"
       }}
    else
      {:error, :throttled} -> {:error, "the feishu registration answered HTTP 429"}
      error -> error
    end
  end

  def begin(_domain, _name, _opts), do: {:error, "unknown platform"}

  @doc """
  Asks once whether the registration on `domain` made its app.

  `{:pending, domain}` asks again after the interval, on the domain it
  names; `:slow_down` asks again after a longer one. `{:error, reason}` ends
  the registration: `:denied`, `:expired`, or a text.
  """
  @spec poll(domain(), String.t()) ::
          {:ok, app()}
          | {:pending, domain()}
          | {:slow_down, domain()}
          | {:error, :denied | :expired | String.t()}
  def poll(domain, device_code)
      when is_map_key(@accounts, domain) and is_binary(device_code) and device_code != "" do
    with {:ok, answer} <- post(domain, %{"action" => "poll", "device_code" => device_code}) do
      next = if brand(answer) == "lark", do: "lark", else: domain

      case answer do
        %{"client_id" => app_id, "client_secret" => secret}
        when is_binary(app_id) and app_id != "" and is_binary(secret) and secret != "" ->
          {:ok,
           %{
             app_id: app_id,
             app_secret: secret,
             open_id: open_id(answer),
             brand: brand(answer),
             domain: next
           }}

        %{"error" => "slow_down"} ->
          {:slow_down, next}

        %{"error" => "access_denied"} ->
          {:error, :denied}

        %{"error" => "expired_token"} ->
          {:error, :expired}

        %{"error" => error}
        when is_binary(error) and error not in ["", "authorization_pending"] ->
          {:error, String.trim("#{error} #{answer["error_description"]}")}

        _pending ->
          {:pending, next}
      end
    else
      # Throttled (HTTP 429): ask again later.
      {:error, :throttled} -> {:slow_down, domain}
      error -> error
    end
  end

  def poll(_domain, _device_code), do: {:error, "unknown registration"}

  # ---- HTTP ----

  defp post(domain, form) do
    url = SystemsRuntime.get_env(:salix_im, :lark_registration_base_urls, @accounts)[domain]

    case Req.post(url <> @endpoint, form: form, retry: false, receive_timeout: 15_000) do
      # Throttled, with or without a JSON body: ask again later.
      {:ok, %{status: 429}} ->
        {:error, :throttled}

      {:ok, %{status: status, body: body}} when is_map(body) and status in 200..499 ->
        {:ok, body}

      {:ok, %{status: status}} ->
        {:error, "the #{domain} registration answered HTTP #{status}"}

      {:error, exception} ->
        {:error, "the #{domain} registration failed: " <> Exception.message(exception)}
    end
  end

  defp client_secret_offered(init) do
    if "client_secret" in List.wrap(init["supported_auth_methods"]),
      do: :ok,
      else: {:error, "app registration with a client secret is not offered"}
  end

  defp device_code(%{"device_code" => code} = begun) when is_binary(code) and code != "" do
    case begun["user_code"] ||
           URI.decode_query(URI.parse(to_string(begun["verification_uri_complete"])).query || "")[
             "user_code"
           ] do
      user_code when is_binary(user_code) and user_code != "" -> {:ok, code, user_code}
      _ -> {:error, "no user code"}
    end
  end

  defp device_code(answer),
    do: {:error, to_string(answer["error_description"] || answer["error"] || "no device code")}

  # The page updates the app named by `clientID`.
  defp link(page, user_code, name, app_id) do
    query = %{"user_code" => user_code, "name" => name, "addons" => addons()}

    query =
      if is_binary(app_id) and app_id != "", do: Map.put(query, "clientID", app_id), else: query

    page <> "?" <> URI.encode_query(query)
  end

  # JSON, gzipped, base64url without padding, as the link takes it.
  defp addons,
    do: @addons |> Jason.encode!() |> :zlib.gzip() |> Base.url_encode64(padding: false)

  defp brand(answer), do: get_in(answer, ["user_info", "tenant_brand"])

  defp open_id(answer) do
    case get_in(answer, ["user_info", "open_id"]) do
      id when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  defp positive(value, _default) when is_integer(value) and value > 0, do: value
  defp positive(_value, default), do: default
end
