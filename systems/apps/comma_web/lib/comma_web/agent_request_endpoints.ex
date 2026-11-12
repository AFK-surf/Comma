defmodule CommaWeb.AgentRequestEndpoints do
  @moduledoc """
  An Agent's requests to a person in a Comma Conversation, for the app's
  request cards: `/v1/comma/groups/:group/conversations/:conversation/requests*`.

  A request is a Capability Request (`SalixAgent.CapabilityRequests`), which
  owns its status, deadline and the winning outcome; these routes read and
  answer the ones a Conversation's Agent raised there (`surface_ref`). A member
  sees them when they may read the Conversation. Connecting an account
  (`oauth_authorization`) succeeds on the verified OAuth callback, so a person
  opens the authorization page or declines; a request with `input` first takes
  what the person fills in on the card. What they fill in goes to the OAuth
  flow alone: it is never logged or stored here, and no result to the Agent
  carries it. A credential's owner fills in theirs, and only a Workspace owner
  gives the Workspace its app. A `location` request ends when a person shares
  their device's position once or declines; its card and stream never carry
  the coordinates. `location_events` tells a person's open phone of the requests
  their own messages led to, across their Groups: a phone with location allowed
  answers one without asking. A phone's consent (`computer_use_start` that `env.android`
  raises for a computer's own phone, capability `android_phone`) and a simulator's
  (that `env.screen` raises, capability `ios_simulator`) are allowed or denied by the
  owner of the computer the device is on alone (`decide`).
  A `plugin_install` request (`plugin.request_install`) ends when the
  Workspace installs the plugin, however (`Comma.Plugins.install/4`), or a
  person declines; its card installs the way the Plugins page does.

  Bounds: a read lists only the Conversation's own requests (every pending one
  and the newest finished ones, at most 100 in all); a stream update reads one;
  a person's location stream starts with at most 20 pending requests.
  A store that cannot be read fails the read, never answers with fewer cards.
  """

  require Logger
  require SystemsRuntime.Proc
  import Plug.Conn

  alias SalixAgent.CapabilityRequests

  @card_types ~w(oauth_authorization location computer_use_start plugin_install)
  @max_input_bytes 64 * 1024

  def list(conn, group_id, conversation_id) do
    with_user(conn, fn user, session ->
      case scope(user, session, group_id, conversation_id) do
        {:ok, tenant_id} ->
          case requests(group_id, tenant_id, conversation_id) do
            {:ok, data} -> json(conn, 200, %{data: data})
            error -> error(conn, error)
          end

        error ->
          error(conn, error)
      end
    end)
  end

  @doc "The Conversation's requests now (`event: snapshot`), then each change (`event: request`)."
  def events(conn, group_id, conversation_id) do
    with_user(conn, fn user, session ->
      # Subscribed before the snapshot is read: a request raised meanwhile is
      # in the snapshot or arrives as an event, never neither.
      with {:ok, tenant_id} <- scope(user, session, group_id, conversation_id),
           :ok <- Phoenix.PubSub.subscribe(SalixWeb.PubSub, CapabilityRequests.topic(group_id)),
           {:ok, data} <- requests(group_id, tenant_id, conversation_id) do
        conn =
          conn
          |> put_resp_header("cache-control", "no-cache")
          |> put_resp_header("x-accel-buffering", "no")
          |> put_resp_content_type("text/event-stream")
          |> send_chunked(200)

        case chunk(conn, event("snapshot", %{data: data})) do
          {:ok, conn} ->
            SystemsClock.send_after(
              SystemsRuntime.Proc.self(),
              :agent_requests_tick,
              heartbeat_ms()
            )

            loop(conn, user, session, {group_id, tenant_id, conversation_id})

          {:error, _} ->
            conn
        end
      else
        error -> error(conn, error)
      end
    end)
  end

  @doc """
  The pending location requests the person's own messages led to (`event: snapshot`),
  then each change (`event: request`). A phone holds this while the app is open.
  """
  def location_events(conn) do
    with_user(conn, fn user, session ->
      requester = "comma_user|" <> user["id"]
      topic = CapabilityRequests.location_requester_topic(requester)

      # Subscribed before the snapshot is read, as in `events/3`.
      with :ok <- Phoenix.PubSub.subscribe(SalixWeb.PubSub, topic),
           {:ok, pending} <- CapabilityRequests.pending_location_requests(requester) do
        data = Enum.flat_map(pending, &List.wrap(project_location_request(&1, user, session)))

        conn =
          conn
          |> put_resp_header("cache-control", "no-cache")
          |> put_resp_header("x-accel-buffering", "no")
          |> put_resp_content_type("text/event-stream")
          |> send_chunked(200)

        case chunk(conn, event("snapshot", %{data: data})) do
          {:ok, conn} ->
            SystemsClock.send_after(
              SystemsRuntime.Proc.self(),
              :agent_requests_tick,
              heartbeat_ms()
            )

            location_loop(conn, user, session)

          {:error, _} ->
            conn
        end
      else
        error -> error(conn, error)
      end
    end)
  end

  defp location_loop(conn, user, session) do
    SystemsRuntime.Proc.receive do
      {:location_request_event, group_id, tenant_id, request_id} ->
        case CapabilityRequests.get(group_id, request_id, tenant_id) do
          {:ok, request} ->
            case project_location_request(request, user, session) do
              nil ->
                location_loop(conn, user, session)

              projected ->
                case chunk(conn, event("request", projected)) do
                  {:ok, conn} -> location_loop(conn, user, session)
                  {:error, _} -> conn
                end
            end

          # As in `loop/4`: the client reads the list again rather than miss it.
          _unread ->
            conn
        end

      :agent_requests_tick ->
        with {:ok, _user, _session} <- Comma.Accounts.resolve_session_id(session["id"]),
             {:ok, conn} <- chunk(conn, ": heartbeat\n\n") do
          SystemsClock.send_after(
            SystemsRuntime.Proc.self(),
            :agent_requests_tick,
            heartbeat_ms()
          )

          location_loop(conn, user, session)
        else
          _ -> conn
        end

      _other ->
        location_loop(conn, user, session)
    end
  end

  # What a phone needs to answer it; nil when this session may not read its Conversation.
  defp project_location_request(
         %{
           "group_id" => group_id,
           "surface_ref" => %{"conversation_id" => conversation_id}
         } = request,
         user,
         session
       ) do
    case scope(user, session, group_id, conversation_id) do
      {:ok, _tenant_id} ->
        request |> project() |> Map.put("group_id", group_id)

      _unreadable ->
        nil
    end
  end

  defp project_location_request(_request, _user, _session), do: nil

  def decline(conn, group_id, conversation_id, request_id) do
    with_user(conn, fn user, session ->
      with {:ok, tenant_id} <- scope(user, session, group_id, conversation_id),
           {:ok, request} <- CapabilityRequests.get(group_id, request_id, tenant_id),
           true <- shown_in?(request, conversation_id) || {:error, :not_found},
           {:ok, declined} <- decline_request(request, group_id, tenant_id) do
        end_login(group_id, conversation_id, request)
        json(conn, 200, project(declined))
      else
        error -> error(conn, error)
      end
    end)
  end

  defp decline_request(
         %{"request_type" => "location", "request_id" => request_id},
         group_id,
         tenant
       ) do
    CapabilityRequests.share_location(
      group_id,
      request_id,
      %{"status" => "error", "error" => "The user declined to share their location."},
      tenant
    )
  end

  defp decline_request(
         %{"request_type" => "plugin_install", "request_id" => request_id},
         group_id,
         tenant
       ),
       do: CapabilityRequests.decline_plugin_install(group_id, request_id, tenant)

  defp decline_request(%{"request_id" => request_id}, group_id, tenant),
    do: CapabilityRequests.decline_oauth_authorization(group_id, request_id, tenant)

  @doc "A person's device position, shared once for a location request."
  def share_location(conn, group_id, conversation_id, request_id) do
    with_user(conn, fn user, session ->
      with {:ok, tenant_id} <- scope(user, session, group_id, conversation_id),
           {:ok, %{"request_type" => "location", "status" => "pending"} = request} <-
             CapabilityRequests.get(group_id, request_id, tenant_id),
           true <- shown_in?(request, conversation_id) || {:error, :not_found},
           {:ok, location} <- shared_location(conn.body_params),
           {:ok, shared} <-
             CapabilityRequests.share_location(
               group_id,
               request_id,
               %{"status" => "success", "location" => location},
               tenant_id
             ) do
        json(conn, 200, project(shared))
      else
        {:ok, %{"request_type" => "location"}} -> error(conn, {:error, {:conflict, :not_pending}})
        {:ok, _not_location} -> error(conn, {:error, :not_found})
        error -> error(conn, error)
      end
    end)
  end

  defp shared_location(%{"latitude" => latitude, "longitude" => longitude} = body)
       when is_number(latitude) and latitude >= -90 and latitude <= 90 and
              is_number(longitude) and longitude >= -180 and longitude <= 180 do
    location = %{"latitude" => latitude, "longitude" => longitude}

    case body["accuracy_m"] do
      accuracy when is_number(accuracy) and accuracy >= 0 ->
        {:ok, Map.put(location, "accuracy_m", accuracy)}

      _none ->
        {:ok, location}
    end
  end

  defp shared_location(_body), do: {:error, {:bad_request, "invalid location"}}

  @doc "The computer's owner allows or denies an Agent's use of their phone in this Conversation: `{approved}`."
  def decide(conn, group_id, conversation_id, request_id) do
    with_user(conn, fn user, session ->
      with {:ok, approved} <- approved(conn.body_params),
           {:ok, tenant_id} <- scope(user, session, group_id, conversation_id),
           {:ok, %{"status" => "pending", "request_type" => "computer_use_start"} = request} <-
             CapabilityRequests.get(group_id, request_id, tenant_id),
           true <- shown_in?(request, conversation_id) || {:error, :not_found},
           device_id when is_binary(device_id) <-
             get_in(request, ["request_payload", "computer_use_start", "device_id"]) ||
               {:error, :not_found},
           {:ok, _device} <-
             SalixEnv.Control.get_owned_environment(device_id, group_id, tenant_id, user["id"]),
           {:ok, decided} <-
             CapabilityRequests.answer_computer_use_start(
               group_id,
               request_id,
               approved,
               tenant_id
             ) do
        json(conn, 200, project(decided))
      else
        {:ok, %{"request_type" => "computer_use_start"}} ->
          error(conn, {:error, {:conflict, :not_pending}})

        {:ok, _other} ->
          error(conn, {:error, :not_found})

        error ->
          error(conn, error)
      end
    end)
  end

  defp approved(%{"approved" => approved}) when is_boolean(approved), do: {:ok, approved}
  defp approved(_body), do: {:error, {:bad_request, "approved must be true or false"}}

  # A declined CLI login's command stops in its sandbox. Stopped or not, the card has ended.
  defp end_login(group_id, conversation_id, request) do
    case get_in(request, ["request_payload", "oauth_authorization", "login"]) do
      login when is_binary(login) ->
        _ =
          SalixWeb.StationTasks.ask(group_id, conversation_id, "task.login_answer", %{
            "login" => login,
            "cancel" => true
          })

        :ok

      _not_a_login ->
        :ok
    end
  end

  @doc "What the person filled in on a request's card."
  def input(conn, group_id, conversation_id, request_id) do
    with_user(conn, fn user, session ->
      with {:ok, %{"id" => workspace_id, "salix_tenant_id" => tenant_id}}
           when is_binary(tenant_id) <-
             Comma.Conversations.authorize_read(user, session, group_id, conversation_id),
           {:ok, %{"status" => "pending"} = request} <-
             CapabilityRequests.get(group_id, request_id, tenant_id),
           true <- shown_in?(request, conversation_id) || {:error, :not_found},
           oauth = get_in(request, ["request_payload", "oauth_authorization"]),
           %{"kind" => kind} <- oauth["input"] || {:error, {:conflict, :no_input}},
           :ok <- may_fill(kind, oauth, user, workspace_id, group_id),
           {:ok, answered} <-
             fill(
               kind,
               oauth,
               conn.body_params,
               {group_id, conversation_id, request_id, tenant_id}
             ) do
        json(conn, 200, project(answered))
      else
        {:ok, _not_pending} -> error(conn, {:error, {:conflict, :not_pending}})
        error -> error(conn, error)
      end
    end)
  end

  defp may_fill("app", _oauth, user, workspace_id, group_id) do
    case Comma.Workspaces.authorize_group_owner(workspace_id, group_id, user["id"]) do
      {:ok, _workspace} -> :ok
      _not_owner -> {:error, :forbidden}
    end
  end

  # A login in a Task's sandbox says whose it is on its card.
  defp may_fill("paste", %{"owner" => owner}, user, _workspace_id, _group_id) do
    if owner == "comma_user|" <> user["id"], do: :ok, else: {:error, :forbidden}
  end

  defp may_fill("paste", _oauth, _user, _workspace_id, _group_id), do: {:error, :forbidden}

  defp may_fill(_kind, %{"state" => state}, user, _workspace_id, _group_id) do
    case SalixStore.OAuth.AuthState.get(state) do
      {:ok, %{"owner" => owner}} when is_binary(owner) and owner != "" ->
        if owner == "comma_user|" <> user["id"], do: :ok, else: {:error, :forbidden}

      {:ok, _shared} ->
        :ok

      _gone ->
        {:error, {:conflict, :expired}}
    end
  end

  # What was pasted goes to the login's command in the sandbox, which ends the card when it ends.
  defp fill(
         "paste",
         %{"login" => login},
         %{"value" => value},
         {group_id, conversation_id, request_id, tenant_id}
       )
       when is_binary(value) and byte_size(value) <= @max_input_bytes do
    if String.trim(value) == "" do
      {:error, {:bad_request, "the value is empty"}}
    else
      with {:ok, %{"ok" => true}} <-
             SalixWeb.StationTasks.ask(group_id, conversation_id, "task.login_answer", %{
               "login" => login,
               "value" => value
             }) do
        CapabilityRequests.get(group_id, request_id, tenant_id)
      else
        {:ok, _refused} -> {:error, {:conflict, :not_waiting}}
        {:error, _} = error -> error
      end
    end
  end

  defp fill(
         "secret",
         %{"state" => state},
         %{"value" => value},
         {group_id, _conversation_id, request_id, tenant_id}
       )
       when is_binary(value) and byte_size(value) <= @max_input_bytes do
    if String.trim(value) == "" do
      {:error, {:bad_request, "the value is empty"}}
    else
      _page = SalixWeb.OAuthFlow.submit_secret(state, value)
      CapabilityRequests.get(group_id, request_id, tenant_id)
    end
  end

  defp fill(
         "app",
         %{"state" => state},
         %{"client_id" => client_id, "client_secret" => client_secret},
         {group_id, _conversation_id, request_id, tenant_id}
       )
       when is_binary(client_id) and byte_size(client_id) <= @max_input_bytes and
              is_binary(client_secret) and byte_size(client_secret) <= @max_input_bytes do
    with {:ok, url} <- SalixWeb.OAuthFlow.submit_app(state, client_id, client_secret) do
      CapabilityRequests.open_oauth_authorization(group_id, request_id, tenant_id, url)
    end
  end

  defp fill(_kind, _oauth, _body, _where),
    do: {:error, {:bad_request, "the card's fields are required"}}

  defp loop(conn, user, session, {group_id, tenant_id, conversation_id} = scope) do
    SystemsRuntime.Proc.receive do
      {:capability_request_event, ^group_id, request_id} ->
        case CapabilityRequests.get(group_id, request_id, tenant_id) do
          {:ok, request} ->
            if shown_in?(request, conversation_id) do
              case chunk(conn, event("request", project(request))) do
                {:ok, conn} -> loop(conn, user, session, scope)
                {:error, _} -> conn
              end
            else
              loop(conn, user, session, scope)
            end

          # A change it could not read ends the stream, so the client reads
          # the list again rather than miss it until the next reconnect.
          _unread ->
            conn
        end

      # A timer, not quiet time, drives the recheck: steady event traffic
      # cannot postpone it.
      :agent_requests_tick ->
        with {:ok, ^tenant_id} <-
               scope(user, session, group_id, conversation_id),
             {:ok, _user, _session} <- Comma.Accounts.resolve_session_id(session["id"]),
             {:ok, conn} <- chunk(conn, ": heartbeat\n\n") do
          SystemsClock.send_after(
            SystemsRuntime.Proc.self(),
            :agent_requests_tick,
            heartbeat_ms()
          )

          loop(conn, user, session, scope)
        else
          _ -> conn
        end

      _other ->
        loop(conn, user, session, scope)
    end
  end

  defp scope(user, session, group_id, conversation_id) do
    case Comma.Conversations.authorize_read(user, session, group_id, conversation_id) do
      {:ok, %{"salix_tenant_id" => tenant_id}} when is_binary(tenant_id) -> {:ok, tenant_id}
      {:ok, _workspace} -> {:error, :not_found}
      error -> error
    end
  end

  defp requests(group_id, tenant_id, conversation_id) do
    with {:ok, records} <-
           CapabilityRequests.list_conversation(group_id, tenant_id, conversation_id) do
      {:ok,
       records
       |> Enum.filter(&shown_in?(&1, conversation_id))
       |> Enum.map(&project/1)}
    end
  end

  # A card shows the requests the Conversation's Agent raised there, of the kinds the app draws.
  # Of computer_use_start, only a phone's consent and a simulator's have a card.
  defp shown_in?(
         %{
           "request_type" => "computer_use_start",
           "request_payload" => %{"computer_use_start" => %{"capability" => capability}},
           "surface_kind" => "conversation",
           "surface_ref" => %{"conversation_id" => conversation_id}
         },
         conversation_id
       )
       when capability in ["android_phone", "ios_simulator"],
       do: true

  defp shown_in?(%{"request_type" => "computer_use_start"}, _conversation_id), do: false

  defp shown_in?(
         %{
           "request_type" => type,
           "surface_kind" => "conversation",
           "surface_ref" => %{"conversation_id" => conversation_id}
         },
         conversation_id
       )
       when type in @card_types,
       do: true

  defp shown_in?(_request, _conversation_id), do: false

  # What a card needs, without the tenant, session, Agent and tool call it came from.
  defp project(%{"request_type" => "computer_use_start"} = request) do
    phone = get_in(request, ["request_payload", "computer_use_start"]) || %{}
    common = project_common(request)

    common
    |> Map.put(
      "outcome",
      if(common["status"] == "completed",
        do:
          if(get_in(request, ["response_payload", "approved"]) == true,
            do: "allowed",
            else: "denied"
          )
      )
    )
    |> Map.put("phone", %{
      "title" => phone["title"],
      "target" => phone["target"],
      "device_id" => phone["device_id"]
    })
  end

  defp project(%{"request_type" => "location"} = request) do
    request
    |> project_common()
    |> Map.put("location", %{
      "reason" => get_in(request, ["request_payload", "location", "reason"]) || ""
    })
  end

  defp project(%{"request_type" => "plugin_install"} = request) do
    plugin = get_in(request, ["request_payload", "plugin_install"]) || %{}

    request
    |> project_common()
    |> Map.put(
      "plugin",
      %{
        "id" => plugin["plugin_id"],
        "name" => plugin["name"],
        "reason" => plugin["reason"] || "",
        "workspace_id" => plugin["workspace_id"]
      }
      |> put_present("brand", plugin["brand"])
    )
  end

  defp project(request) do
    oauth = get_in(request, ["request_payload", "oauth_authorization"]) || %{}
    response = request["response_payload"] || %{}
    status = status(request)

    request
    |> project_common()
    |> Map.put(
      "oauth",
      %{
        "provider" => oauth["provider"],
        "alias" => oauth["alias"],
        "reason" => oauth["reason"],
        "scopes" => List.wrap(oauth["scopes"])
      }
      # The page to authorize on matters only while the request waits.
      |> put_present("authorization_url", status == "pending" && oauth["authorization_url"])
      |> put_present("account", response["provider_account_name"])
      # What a secret is called stays for its receipt; what the card asks does not.
      |> put_present("label", get_in(oauth, ["input", "label"]))
      |> put_input(status == "pending" && oauth["input"])
    )
  end

  defp project_common(request) do
    status = status(request)

    %{
      "id" => request["request_id"],
      "type" => request["request_type"],
      "status" => status,
      "outcome" => outcome(status, request["response_payload"] || %{}),
      "expires_at" => request["expires_at"],
      "created_at" => request["created_at"],
      "updated_at" => request["updated_at"],
      "conversation_id" => get_in(request, ["surface_ref", "conversation_id"]),
      "source_message_id" => get_in(request, ["surface_ref", "message_id"])
    }
  end

  defp put_input(map, %{"kind" => _} = input), do: Map.put(map, "input", input)
  defp put_input(map, _input), do: map

  # A pending request past its deadline has expired, though nothing settled it yet.
  defp status(%{"status" => "pending", "expires_at" => expires_at})
       when is_integer(expires_at) do
    if SystemsClock.system_time(:second) >= expires_at, do: "expired", else: "pending"
  end

  defp status(%{"status" => status}) when is_binary(status), do: status
  defp status(_request), do: "pending"

  defp outcome("completed", %{"status" => "installed"}), do: "installed"
  defp outcome("completed", %{"status" => "connected"}), do: "connected"
  defp outcome("completed", %{"status" => "declined"}), do: "declined"
  defp outcome("completed", %{"status" => "confirmed"}), do: "connected"
  defp outcome("completed", %{"status" => "success"}), do: "shared"
  defp outcome("completed", %{"status" => "error"}), do: "declined"
  defp outcome(_status, _response), do: nil

  defp put_present(map, key, value) when is_binary(value) and value != "",
    do: Map.put(map, key, value)

  defp put_present(map, _key, _value), do: map

  defp event(name, data), do: "event: #{name}\ndata: #{Jason.encode!(data)}\n\n"

  defp heartbeat_ms,
    do: SystemsRuntime.get_env(:comma_web, :agent_requests_heartbeat_ms, 25_000)

  defp with_user(conn, fun) do
    case conn.assigns do
      %{comma_user: user, comma_session: session} when is_map(user) and is_map(session) ->
        fun.(user, session)

      _ ->
        json(conn, 401, %{error: "unauthorized"})
    end
  end

  defp error(conn, {:error, :not_found}), do: json(conn, 404, %{error: "not_found"})
  defp error(conn, {:error, :forbidden}), do: json(conn, 403, %{error: "forbidden"})

  defp error(conn, {:error, {:bad_request, message}}) when is_binary(message),
    do: json(conn, 400, %{error: "bad_request", message: message})

  defp error(conn, {:error, {:conflict, _}}), do: json(conn, 409, %{error: "conflict"})

  defp error(conn, reason) do
    Logger.info("agent request route failed: #{inspect(reason) |> String.slice(0, 300)}")
    json(conn, 503, %{error: "temporarily_unavailable"})
  end

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
