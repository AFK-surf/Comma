defmodule SalixStore.OAuth.Adapters.Lark do
  @moduledoc """
  Lark (`open.larksuite.com`) user sign-in: OAuth 2.0 with PKCE and refresh
  through Lark's `/authen/v2/oauth/token`. The provider app is a Lark custom
  app; its App ID and App Secret are the client credentials.

  A sign-in lets the bot of a Lark connect find and read as that person what
  they may see: documents, wiki pages, meetings, meeting notes and Minutes
  recordings (`SalixIM.Provider.Lark`). A command a sandbox runs with the
  sign-in (`comma exec --credential`) also sends messages as that person
  (`im:message.send_as_user`). It asks a document's owner for access as that
  person (`docs:permission.member:apply`). `offline_access` makes Lark return a
  refresh token; Lark asks the person to sign in again after 365 days. Lark
  has no revocation endpoint.

  A sign-in that names only on-demand scopes (`on_demand_scopes/0`: table
  reads, document edits) asks for them on top of the default sign-in. Like
  Feishu, Lark keeps what a person granted before, so the new token holds
  both. Any other
  list of scopes replaces the defaults.
  """
  @behaviour SalixStore.OAuth.Adapter

  alias SalixStore.OAuth.Adapter

  # The names follow the official larksuite/cli (`vc +search`, `vc +notes`,
  # `note`, `minutes`, `doc`, `drive`, `wiki`, `im`, `contact`, `calendar`);
  # a scope the app does not offer as a user scope makes the sign-in page
  # refuse the whole request. Each name is checked
  # against the platform's scope catalog for the user identity. The
  # sign-in asks for no private chat scope and no administration.
  @default_scopes ~w(
    vc:meeting.search:read
    vc:meeting.meetingevent:read
    vc:record:readonly
    vc:note:read
    minutes:minutes:readonly
    minutes:minutes.basic:read
    minutes:minutes.artifacts:read
    minutes:minutes.search:read
    minutes:minutes.media:export
    docx:document:readonly
    search:docs:read
    wiki:wiki
    wiki:wiki:readonly
    wiki:node:read
    wiki:node:retrieve
    wiki:space:read
    wiki:space:retrieve
    drive:drive
    drive:drive:readonly
    drive:drive:version
    drive:drive:version:readonly
    drive:drive.metadata:readonly
    drive:drive.search:readonly
    space:document:retrieve
    docs:document.comment:read
    docs:document.media:download
    docs:permission.member:retrieve
    docs:permission.member:apply
    docs:permission.setting:read
    im:message.group_msg:get_as_user
    im:message.send_as_user
    calendar:calendar
    calendar:calendar.event:create
    calendar:calendar.event:delete
    calendar:calendar.event:join
    calendar:calendar.event:read
    calendar:calendar.event:reply
    calendar:calendar.event:transfer
    calendar:calendar.event:update
    calendar:calendar.free_busy:read
    calendar:calendar:create
    calendar:calendar:delete
    calendar:calendar:read
    calendar:calendar:readonly
    calendar:calendar:update
    calendar:room:readonly
    contact:contact.base:readonly
    contact:department.base:readonly
    contact:department.organize:readonly
    contact:job_title:readonly
    contact:user.base:readonly
    contact:user.basic_profile:readonly
    contact:user.department:readonly
    contact:user.department_path:readonly
    contact:user.dotted_line_leader_info.read
    contact:user.email:readonly
    contact:user.employee:readonly
    contact:user.employee_id:readonly
    contact:user.id:readonly
    contact:user.phone:readonly
    contact:user:search
    contact:work_city:readonly
    directory:department.base:read
    directory:department.count:read
    directory:department.department_path:read
    directory:department.has_child:read
    directory:department.leader:read
    directory:department.name:read
    directory:department.organization:read
    directory:department.parent_id:read
    directory:department:list
    directory:department:read
    directory:department:search
    directory:employee.base.avatar:read
    directory:employee.base.base:read
    directory:employee.base.department:read
    directory:employee.base.department_path:read
    directory:employee.base.description:read
    directory:employee.base.dotted_line_leaders:read
    directory:employee.base.email:read
    directory:employee.base.enterprise_email:read
    directory:employee.base.leader:read
    directory:employee.base.leader_id:read
    directory:employee.base.mobile:read
    directory:employee.base.name.another_name:read
    directory:employee.base.name.first_name:read
    directory:employee.base.name.last_name:read
    directory:employee.base.name.name:read
    directory:employee.work.base_work:read
    directory:employee.work.extension_number:read
    directory:employee.work.job_number:read
    directory:employee.work.job_title:read
    directory:employee.work.join_date:read
    directory:employee.work.positions:read
    directory:employee.work.work_country_or_region:read
    directory:employee.work.work_place:read
    directory:employee.work.work_station:read
    directory:employee:list
    directory:employee:read
    directory:employee:search
    directory:job_title.base:read
    directory:place.base:read
    im:chat.announcement:read
    im:chat.chat_pins:read
    im:chat.members:read
    im:chat.members:write_only
    im:chat.nickname:read
    im:chat.user_setting:read
    im:chat:create_by_user
    im:chat:read
    im:chat:readonly
    im:feed.flag:read
    im:feed.flag:write
    im:feed.shortcut:read
    im:feed.shortcut:write
    im:feed_group_v1:read
    im:feed_group_v1:write
    im:message.pins:read
    im:message.pins:write_only
    im:message.reactions:read
    im:message.reactions:write_only
    im:message:recall
    im:message:update
    im:resource
    minutes:minutes
    minutes:minutes.upload:write
    minutes:minutes:update
    minutes:permission:apply
    search:bot
    search:message
    vc:meeting.bot.join:write
    vc:meeting.bot.manage:write
    vc:meeting.interaction:write
    vc:meeting.message:write
    vc:recording:read
    vc:room:readonly
    offline_access
  )

  @doc "The scopes a sign-in asks for. The app needs each as a user scope."
  @spec default_scopes() :: [String.t()]
  def default_scopes, do: @default_scopes

  # Scopes a sign-in does not ask for by default, by the need that asks for
  # them: reading spreadsheets and Base, and editing documents and their
  # comments, as the person. A default sign-in asks for none of them, so an
  # app that does not offer them as user scopes still lets people sign in.
  # The names are the ones the app's own document scopes use.
  @on_demand_scopes %{
    "tables" => ~w(sheets:spreadsheet:readonly bitable:app:readonly),
    "document_writes" => ~w(docx:document docx:document:write_only
                            docs:document.comment:create docs:document.comment:write_only
                            docs:document.media:upload)
  }

  @doc """
  The user scopes one need asks for beyond the default sign-in: `tables`
  (spreadsheet and Base reads) or `document_writes` (document and comment
  edits). The permission import offers all of them as user scopes.
  """
  @spec on_demand_scopes() :: %{String.t() => [String.t()]}
  def on_demand_scopes, do: @on_demand_scopes

  @on_demand_scope_names @on_demand_scopes |> Map.values() |> List.flatten()

  # No scopes asks for the default sign-in. Scopes that are all on-demand
  # ones are added to the default sign-in: the platform keeps what a person
  # granted before, and a first sign-in for a table read also reads
  # documents. Only such a request fails when the app does not offer the
  # scope. Any other list replaces the defaults, for an app that offers
  # fewer scopes.
  defp requested_scopes(scopes) when scopes in [nil, []], do: @default_scopes

  defp requested_scopes(scopes) do
    if Enum.all?(scopes, &(&1 in @on_demand_scope_names)),
      do: Enum.uniq(@default_scopes ++ scopes),
      else: Enum.uniq(scopes ++ ["offline_access"])
  end

  @impl true
  def default_env_var, do: "LARK_USER_ACCESS_TOKEN"

  @impl true
  def authorization_url(app, req) do
    if Enum.any?(
         [app["client_id"], req["redirect_uri"], req["code_challenge"]],
         &Adapter.blank?/1
       ) do
      {:error, "lark oauth: client_id, redirect_uri, and PKCE challenge are required"}
    else
      # Without offline_access the sign-in gives no refresh token and ends with
      # its access token, about two hours later.
      scopes = requested_scopes(req["scopes"])

      query =
        Adapter.encode_query([
          {"client_id", app["client_id"]},
          {"redirect_uri", req["redirect_uri"]},
          {"state", req["state"] || ""},
          {"scope", Enum.join(scopes, " ")},
          {"code_challenge", req["code_challenge"]},
          {"code_challenge_method", "S256"}
        ])

      {:ok,
       endpoint("authorize_url", "https://accounts.larksuite.com/open-apis/authen/v1/authorize") <>
         "?" <> query}
    end
  end

  @impl true
  def exchange_code(app, ctx, code) do
    if Adapter.blank?(ctx["code_verifier"]) do
      {:error, "lark oauth: PKCE verifier is required"}
    else
      with {:ok, parsed} <-
             token_request(app, %{
               "grant_type" => "authorization_code",
               "code" => code,
               "redirect_uri" => ctx["redirect_uri"],
               "code_verifier" => ctx["code_verifier"]
             }),
           {:ok, account} <- account(parsed["access_token"]) do
        {:ok, %{"tokens" => tokens(parsed), "account" => account}}
      end
    end
  end

  @impl true
  def refresh(app, conn) do
    if Adapter.blank?(conn["refresh_token"]) do
      {:error, :reauthorization_required}
    else
      with {:ok, parsed} <-
             token_request(app, %{
               "grant_type" => "refresh_token",
               "refresh_token" => conn["refresh_token"]
             }) do
        refreshed = tokens(parsed)

        {:ok,
         refreshed
         |> Map.put("refresh_token", parsed["refresh_token"] || conn["refresh_token"])
         |> Map.put(
           "refresh_expires_at",
           refreshed["refresh_expires_at"] || conn["refresh_expires_at"]
         )
         |> Map.put(
           "scopes",
           if(Adapter.blank?(parsed["scope"]),
             do: conn["scopes"] || [],
             else: refreshed["scopes"]
           )
         )}
      end
    end
  end

  @impl true
  def revoke(_app, _conn), do: {:error, :revocation_not_supported}

  @impl true
  def validate_credential_value(value, scopes),
    do: Adapter.validate_access_token(value, scopes, "lark oauth")

  @impl true
  def resolve_credential_value(conn, value),
    do: Adapter.resolve_access_token(conn, value, "lark oauth")

  defp token_request(app, body) do
    if Adapter.blank?(app["client_id"]) or Adapter.blank?(app["client_secret"]) do
      {:error, "lark oauth: client credentials are required"}
    else
      body =
        Map.merge(body, %{
          "client_id" => app["client_id"],
          "client_secret" => app["client_secret"]
        })

      with {:ok, parsed} <-
             request(:post, endpoint("token_url", api("/authen/v2/oauth/token")), json: body) do
        if Adapter.blank?(parsed["access_token"]),
          do: {:error, "lark oauth: token response missing access_token"},
          else: {:ok, parsed}
      end
    end
  end

  defp account(access_token) do
    case request(:get, endpoint("api_url", api("/authen/v1/user_info")),
           auth: {:bearer, access_token}
         ) do
      {:ok, %{"data" => %{"open_id" => open_id} = user}}
      when is_binary(open_id) and open_id != "" ->
        {:ok,
         %{
           "provider_account_id" => open_id,
           "provider_account_name" => user["name"] || user["en_name"] || open_id,
           "metadata" => %{
             "open_id" => open_id,
             "union_id" => user["union_id"],
             "name" => user["name"],
             "email" => user["enterprise_email"] || user["email"],
             "tenant_key" => user["tenant_key"]
           }
         }}

      {:error, _} = error ->
        error

      _ ->
        {:error, "lark oauth: user info response missing open_id"}
    end
  end

  defp tokens(parsed),
    do: %{
      "access_token" => parsed["access_token"],
      "refresh_token" => parsed["refresh_token"],
      "token_type" => parsed["token_type"] || "Bearer",
      "scopes" => Adapter.split_scopes(parsed["scope"], ~r/\s+/),
      "expires_at" => Adapter.expires_at_ms(parsed["expires_in"]),
      "refresh_expires_at" => Adapter.expires_at_ms(parsed["refresh_token_expires_in"])
    }

  # Lark answers with `code` 0 on success. A refused grant (an expired,
  # revoked or used code or refresh token) is `invalid_grant`. Provider bodies
  # and transport exceptions can contain credentials; return only safe
  # classifications.
  defp request(method, url, opts) do
    case Req.request(
           [
             method: method,
             url: url,
             receive_timeout: 15_000,
             retry: false,
             redirect: false,
             headers: [{"accept", "application/json"}]
           ] ++ opts
         ) do
      {:ok, %{status: status, body: %{"code" => 0} = body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{body: %{"error" => "invalid_grant"}}} ->
        {:error, :reauthorization_required}

      {:ok, %{status: status, body: %{"code" => code}}} ->
        {:error, "lark oauth: provider returned HTTP #{status} code #{code}"}

      {:ok, %{status: status}} ->
        {:error, "lark oauth: provider returned HTTP #{status}"}

      {:error, _} ->
        {:error, "lark oauth: provider request failed"}
    end
  end

  defp api(path), do: "https://open.larksuite.com/open-apis" <> path

  defp endpoint(key, fallback), do: Adapter.endpoint("lark", key, fallback)
end
