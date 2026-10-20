defmodule SalixIM.ProviderTest do
  require SystemsRuntime.Proc

  @moduledoc """
  SalixIM.Provider production backend for the unified IM tools. Everything
  external is mocked: Slack and WeChat ride a Bandit mock HTTP API, and the
  control plane lives on the Fake S3 backend.
  """
  use SystemsClock.Case, async: false
  use SalixStore.QueueCase, queues: [:feishu_mirror_outbox]
  use SystemsClock.Test, scope: ["Elixir.Salix"]

  @incident_trigger Path.join([
                      __DIR__,
                      "fixtures",
                      "slack_recipient_incident",
                      "notion_owner_table.json"
                    ])
                    |> File.read!()
                    |> Jason.decode!()
                    |> Map.fetch!("trigger")

  alias SalixStore.{Ids, Keys, ULID}
  alias SystemsRuntime.Agent
  alias SalixIM.{ConversationServer, Conversations, Provider}
  alias SalixIM.ConversationSeedInput
  alias SalixIM.TestSupport.BanditServer

  import SalixIM.TestSupport.ProviderFixture,
    only: [
      seed_connect: 4,
      seed_raw_connect: 4,
      seed_legacy_slack_connect_without_inbound: 3,
      create_control_agent: 2,
      create_slack_task!: 3,
      create_slack_task!: 4,
      create_slack_task!: 5,
      call: 5,
      call: 6
    ]

  import SystemsRuntime.Test, only: [capture_log: 1]

  alias SalixIM.ProviderTest.{MockSlack, FakeTenantAppStore, EmptyPluginStore}

  defmodule FeishuMirrorFake do
    @moduledoc "Feishu mirror adapter and reader: accepts writes, serves scripted search rows."

    def setup(test_pid, rows) do
      SystemsRuntime.PersistentTerm.put({__MODULE__, :test_pid}, test_pid)
      SystemsRuntime.PersistentTerm.put({__MODULE__, :rows}, rows)
    end

    def record_batch(_rows), do: :ok

    def search(scope, opts) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.PersistentTerm.get({__MODULE__, :test_pid}),
        {:feishu_mirror_search, scope, opts}
      )

      rows =
        SystemsRuntime.PersistentTerm.get({__MODULE__, :rows})
        |> Enum.filter(&(&1["app_id"] == scope["app_id"]))
        |> Enum.drop_while(
          &(opts[:cursor_message_id] && &1["message_id"] != opts[:cursor_message_id])
        )
        |> Enum.drop(if(opts[:cursor_message_id], do: 1, else: 0))

      {page, rest} = Enum.split(rows, opts[:limit])
      last = List.last(page)

      {:ok,
       %{
         messages: page,
         has_more?: rest != [],
         next_cursor: if(rest != [], do: {last["create_time_us"], last["message_id"]})
       }}
    end
  end

  defmodule FeishuMirrorFailingOutbox do
    @moduledoc false
    def append(_row, _kind), do: {:error, :database_down}
  end

  defmodule BindingBarrierS3 do
    @moduledoc false
    @behaviour SalixStore.S3
    alias SalixStore.S3.Fake

    def put(key, body, opts) do
      result = Fake.put(key, body, opts)

      with {:ok, _} <- result,
           {parent, ^key} <- Process.get(:binding_barrier),
           %{"binding_status" => "active", "binding_token" => token} = binding <-
             Jason.decode!(IO.iodata_to_binary(body)),
           false <- Ids.valid_participant_id?(binding["participant_id"]) do
        # Hold this caller before it can send a participant mutation. A trace
        # notification can arrive after that request has already been sent.
        Process.delete(:binding_barrier)

        SystemsRuntime.Proc.send(
          parent,
          {:incomplete_bind_parked, SystemsRuntime.Proc.self(), token, binding}
        )

        SystemsRuntime.Proc.receive do
          :release_incomplete_bind -> :ok
        end
      end

      result
    end

    defdelegate put_stream(key, stream, opts), to: Fake
    defdelegate multipart_create(key, opts), to: Fake
    defdelegate multipart_upload_part(key, id, part, body), to: Fake
    defdelegate multipart_complete(key, id, parts), to: Fake
    defdelegate multipart_abort(key, id), to: Fake
    defdelegate multipart_uploads(key, opts), to: Fake
    defdelegate get(key, opts), to: Fake
    defdelegate stream(key, opts), to: Fake
    defdelegate head(key), to: Fake
    defdelegate delete(key, opts), to: Fake
    defdelegate list(key, opts), to: Fake
  end

  defmodule EventArchiveRecorder do
    @moduledoc false
    @behaviour SalixAgent.EventArchive

    @impl true
    def reserve(fact) do
      reservation = %{seq: next_sequence()}

      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_im, :event_archive_test_pid),
        {:archive_reserved, fact, reservation}
      )

      reservation
    end

    @impl true
    def record(fact) do
      seq = get_in(fact, [:reservation, :seq]) || next_sequence()

      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_im, :event_archive_test_pid),
        {:archived, Map.put(fact, :test_seq, seq)}
      )

      :ok
    end

    defp next_sequence do
      case SystemsRuntime.get_env(:salix_im, :event_archive_test_sequence) do
        sequence when SystemsRuntime.Proc.is_process(sequence) ->
          Agent.get_and_update(sequence, &{&1 + 1, &1 + 1})

        _missing ->
          SystemsRuntime.Proc.unique_integer([:positive, :monotonic])
      end
    end
  end

  defmodule CommitBarrierProvider do
    @moduledoc false
    @behaviour SalixAgent.Tools.ImRouter

    @impl true
    def list_connects(agent_id), do: SalixIM.Provider.list_connects(agent_id)

    @impl true
    def provider_manual(platform), do: SalixIM.Provider.provider_manual(platform)

    @impl true
    def call_api(agent_id, platform, api, args) do
      result = SalixIM.Provider.call_api(agent_id, platform, api, args)

      case result do
        {:ok, %{"inserted" => true} = committed} ->
          owner = SystemsRuntime.fetch_env!(:salix_im, :event_archive_test_pid)

          SystemsRuntime.Proc.send(
            owner,
            {:canonical_message_committed, SystemsRuntime.Proc.self(), committed}
          )

          SystemsRuntime.Proc.receive do
            :release_committed_provider_call -> result
          end

        _other ->
          result
      end
    end
  end

  @png <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, "vfs-image-bytes">>
  @webp <<"RIFF", 16::little-32, "WEBPVP8 ", "vfs-webp-bytes">>
  # Fixed far-future expiry keeps valid capability assertions independent of
  # this module's multi-minute runtime. Expired behavior uses an explicit past
  # value in the same test.
  @valid_meeting_activation_expires_at 4_102_444_800

  defmodule TelegramMediaAPI do
    import Plug.Conn
    def init(opts), do: opts

    def call(conn, _opts) do
      case List.last(conn.path_info) do
        "getFile" ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(
            200,
            Jason.encode!(%{"ok" => true, "result" => %{"file_path" => "photos/test.jpg"}})
          )

        "test.jpg" ->
          send_resp(conn, 200, "telegram image bytes")

        _ ->
          send_resp(conn, 404, "")
      end
    end
  end

  defmodule MockProviderRuntime do
    @moduledoc "Recording mock for Telegram getUpdates and WeChat ClawBot getupdates."
    use Elixir.Agent
    import Plug.Conn

    def start_link(_ \\ []),
      do:
        Agent.start_link(
          fn ->
            %{
              telegram_updates: [],
              telegram_delays: %{},
              wechat_body: %{"ret" => 0, "msgs" => []},
              wechat_cdn_status: 200,
              feishu_reply_response:
                {200,
                 %{
                   "code" => 0,
                   "msg" => "ok",
                   "data" => %{
                     "message_id" => "om_reply_sent",
                     "chat_id" => "oc_thread",
                     "thread_id" => "omt_thread"
                   }
                 }},
              feishu_file_response:
                {200, %{"code" => 0, "msg" => "ok", "data" => %{"file_key" => "file-key-1"}}},
              feishu_messages: [],
              feishu_message_responder: nil,
              feishu_chat_members_responder: nil,
              feishu_token_responses: [],
              feishu_token_rejections: 0,
              feishu_token_rejection_code: nil,
              feishu_resource:
                {200, [{"content-type", "application/octet-stream"}], "feishu-resource-bytes"},
              feishu_reactions: [],
              feishu_reaction_responder: nil,
              feishu_reply_responder: nil,
              feishu_card_patch_responder: nil,
              requests: []
            }
          end,
          name: __MODULE__
        )

    def telegram_updates(updates),
      do: Agent.update(__MODULE__, &%{&1 | telegram_updates: updates})

    def telegram_delay(token, ms),
      do: Agent.update(__MODULE__, &put_in(&1.telegram_delays[to_string(token)], ms))

    # Holds `token`'s reply until a request from `other` arrives after this
    # call; requests from earlier passes do not count.
    def telegram_hold_until_seen(token, other),
      do:
        Agent.update(
          __MODULE__,
          &put_in(
            &1.telegram_delays[to_string(token)],
            {:until_seen, to_string(other), length(&1.requests)}
          )
        )

    defp await_telegram_request(token, since) do
      # The handler waits, not the Agent that runs the update function.
      waiter = SystemsRuntime.Proc.self()

      seen? =
        Agent.get_and_update(__MODULE__, fn state ->
          # Requests are newest first; only those after `since` count.
          newer = Enum.take(state.requests, length(state.requests) - since)

          if Enum.any?(newer, &(&1[:kind] == :telegram and &1[:token] == token)),
            do: {true, state},
            else:
              {false,
               Map.update(state, :request_waiters, [{token, waiter}], &[{token, waiter} | &1])}
        end)

      # No real-time fallback: a poll that serializes connects never sends
      # the other request, and the test fails on its ExUnit timeout.
      unless seen? do
        SystemsRuntime.Proc.receive do
          {__MODULE__, :request_seen} -> :ok
        end
      end
    end

    def wechat_body(body),
      do: Agent.update(__MODULE__, &%{&1 | wechat_body: body})

    def wechat_cdn_status(status),
      do: Agent.update(__MODULE__, &%{&1 | wechat_cdn_status: status})

    def feishu_reply_response(status, body),
      do: Agent.update(__MODULE__, &%{&1 | feishu_reply_response: {status, body}})

    def feishu_file_response(status, body),
      do: Agent.update(__MODULE__, &%{&1 | feishu_file_response: {status, body}})

    def feishu_messages(messages),
      do: Agent.update(__MODULE__, &%{&1 | feishu_messages: messages})

    def feishu_message_responder(fun) when is_function(fun, 1),
      do: Agent.update(__MODULE__, &%{&1 | feishu_message_responder: fun})

    def feishu_chat_members_responder(fun) when is_function(fun, 1),
      do: Agent.update(__MODULE__, &%{&1 | feishu_chat_members_responder: fun})

    def feishu_token_responses(responses) when is_list(responses),
      do: Agent.update(__MODULE__, &%{&1 | feishu_token_responses: responses})

    def feishu_token_rejections(count, code \\ nil)
        when is_integer(count) and count >= 0 and (is_nil(code) or is_integer(code)),
        do:
          Agent.update(
            __MODULE__,
            &%{&1 | feishu_token_rejections: count, feishu_token_rejection_code: code}
          )

    def feishu_resource(mime_type, body),
      do:
        Agent.update(
          __MODULE__,
          &%{&1 | feishu_resource: {200, [{"content-type", mime_type}], body}}
        )

    def feishu_resource_response(status, mime_type, body) when is_binary(mime_type),
      do:
        Agent.update(
          __MODULE__,
          &%{&1 | feishu_resource: {status, [{"content-type", mime_type}], body}}
        )

    def feishu_resource_response(status, headers, body) when is_list(headers),
      do: Agent.update(__MODULE__, &%{&1 | feishu_resource: {status, headers, body}})

    def feishu_resource_disconnect(headers, first_chunk) when is_list(headers),
      do:
        Agent.update(
          __MODULE__,
          &%{&1 | feishu_resource: {:disconnect, headers, first_chunk}}
        )

    def feishu_reply_responder(fun) when is_function(fun, 1),
      do: Agent.update(__MODULE__, &%{&1 | feishu_reply_responder: fun})

    def feishu_card_patch_responder(fun) when is_function(fun, 1),
      do: Agent.update(__MODULE__, &%{&1 | feishu_card_patch_responder: fun})

    def feishu_reactions(reactions),
      do: Agent.update(__MODULE__, &%{&1 | feishu_reactions: reactions})

    def feishu_reaction_responder(fun) when is_function(fun, 1),
      do: Agent.update(__MODULE__, &%{&1 | feishu_reaction_responder: fun})

    def all_requests, do: Agent.get(__MODULE__, & &1.requests)

    def requests(kind),
      do:
        Agent.get(__MODULE__, &Enum.reverse(&1.requests))
        |> Enum.filter(&(&1.kind == kind))

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, raw, conn} = read_full_body(conn)

      case {conn.method, conn.path_info} do
        {"GET", ["bot" <> _token, "getMe"]} ->
          json(conn, 200, %{
            "ok" => true,
            "result" => %{
              "id" => 900,
              "is_bot" => true,
              "first_name" => "Comma",
              "username" => "comma_product_bot"
            }
          })

        {"GET", ["bot" <> token, "getUpdates"]} ->
          conn = fetch_query_params(conn)

          record(%{
            kind: :telegram,
            token: token,
            at_ms: SystemsClock.monotonic_time(:millisecond),
            params: conn.query_params,
            auth: conn |> get_req_header("authorization") |> List.first()
          })

          case Agent.get(__MODULE__, &Map.get(&1.telegram_delays, token, 0)) do
            # Answer only once another connect's request is in flight: a poll
            # that serialized connects would never send that request.
            {:until_seen, other, since} ->
              await_telegram_request(other, since)
              record(%{kind: :telegram_answered, token: token})

            delay when delay > 0 ->
              SystemsRuntime.Proc.sleep(delay)

            _ ->
              :ok
          end

          body = %{"ok" => true, "result" => Agent.get(__MODULE__, & &1.telegram_updates)}
          json(conn, 200, body)

        {"POST", ["bot" <> token, method]} when method in ["sendPhoto", "sendDocument"] ->
          record(%{
            kind: :telegram_api,
            token: token,
            method: method,
            raw: raw,
            content_type: conn |> get_req_header("content-type") |> List.first()
          })

          json(conn, 200, %{
            "ok" => true,
            "result" => %{"message_id" => 77, "chat" => %{"id" => "sent"}}
          })

        {"POST", ["bot" <> token, method]} when method in ["sendMessage", "sendRichMessage"] ->
          params = decode_request_body(raw)

          record(%{
            kind: :telegram_api,
            token: token,
            method: method,
            params: params
          })

          json(conn, 200, %{
            "ok" => true,
            "result" => %{"message_id" => 78, "chat" => %{"id" => params["chat_id"]}}
          })

        {"POST", ["ilink", "bot", "getupdates"]} ->
          record(%{
            kind: :wechat,
            params: decode_request_body(raw),
            auth: conn |> get_req_header("authorization") |> List.first()
          })

          json(conn, 200, Agent.get(__MODULE__, & &1.wechat_body))

        {"POST", ["ilink", "bot", "getuploadurl"]} ->
          params = decode_request_body(raw)

          record(%{
            kind: :wechat_upload_url,
            params: params,
            auth: conn |> get_req_header("authorization") |> List.first()
          })

          json(conn, 200, %{
            "ret" => 0,
            "upload_full_url" => "http://#{conn.host}:#{conn.port}/cdn/upload"
          })

        {"POST", ["ilink", "bot", "sendmessage"]} ->
          params = decode_request_body(raw)

          record(%{
            kind: :wechat_send,
            params: params,
            auth: conn |> get_req_header("authorization") |> List.first()
          })

          json(conn, 200, %{"ret" => 0})

        {"POST", ["cdn", "upload"]} ->
          record(%{
            kind: :wechat_cdn_upload,
            raw: raw,
            content_type: conn |> get_req_header("content-type") |> List.first()
          })

          conn
          |> put_resp_header("x-encrypted-param", "encrypted-download-param")
          |> send_resp(Agent.get(__MODULE__, & &1.wechat_cdn_status), "cdn response")

        {"POST", ["open-apis", "auth", "v3", "tenant_access_token", "internal"]} ->
          params = decode_request_body(raw)
          record(%{kind: :feishu_validate, params: params})

          response =
            Agent.get_and_update(__MODULE__, fn state ->
              case state.feishu_token_responses do
                [response | rest] -> {response, %{state | feishu_token_responses: rest}}
                [] -> {nil, state}
              end
            end)

          case response do
            {status, body} ->
              json(conn, status, body)

            nil ->
              json(conn, 200, %{
                "code" => 0,
                "msg" => "ok",
                "expire" => 7_200,
                "tenant_access_token" => "tenant-token-" <> to_string(params["app_id"])
              })
          end

        {"POST", ["open-apis", "im", "v1", "files"]} ->
          record(%{
            kind: :feishu_file_upload,
            raw: raw,
            auth: conn |> get_req_header("authorization") |> List.first(),
            content_type: conn |> get_req_header("content-type") |> List.first()
          })

          {status, body} = Agent.get(__MODULE__, & &1.feishu_file_response)
          json(conn, status, body)

        {"POST", ["open-apis", "im", "v1", "images"]} ->
          record(%{
            kind: :feishu_image_upload,
            raw: raw,
            auth: conn |> get_req_header("authorization") |> List.first(),
            content_type: conn |> get_req_header("content-type") |> List.first()
          })

          json(conn, 200, %{
            "code" => 0,
            "msg" => "ok",
            "data" => %{"image_key" => "image-key-1"}
          })

        {"POST", ["open-apis", "im", "v1", "messages"]} ->
          conn = fetch_query_params(conn)
          params = decode_request_body(raw)

          record(%{
            kind: :feishu_message,
            params: params,
            query: conn.query_params,
            auth: conn |> get_req_header("authorization") |> List.first()
          })

          json(conn, 200, %{"code" => 0, "msg" => "ok", "data" => %{"message_id" => "om_sent"}})

        {"POST", ["open-apis", "im", "v1", "messages", message_id, "reply"]} ->
          params = decode_request_body(raw)

          record(%{
            kind: :feishu_reply,
            message_id: message_id,
            params: params,
            auth: conn |> get_req_header("authorization") |> List.first()
          })

          {status, body} =
            case Agent.get(__MODULE__, & &1.feishu_reply_responder) do
              nil ->
                Agent.get(__MODULE__, & &1.feishu_reply_response)

              responder ->
                responder.(%{message_id: message_id, params: params})
            end

          json(conn, status, body)

        {"GET", ["open-apis", "im", "v1", "messages"]} ->
          conn = fetch_query_params(conn)

          record(%{
            kind: :feishu_list_messages,
            query: conn.query_params,
            auth: conn |> get_req_header("authorization") |> List.first()
          })

          reject_token? =
            Agent.get_and_update(__MODULE__, fn state ->
              if state.feishu_token_rejections > 0 do
                {true, %{state | feishu_token_rejections: state.feishu_token_rejections - 1}}
              else
                {false, state}
              end
            end)

          if reject_token? do
            code =
              Agent.get(
                __MODULE__,
                &(&1.feishu_token_rejection_code || 99_991_663)
              )

            json(conn, 401, %{"code" => code, "msg" => "tenant access token invalid"})
          else
            responder = Agent.get(__MODULE__, & &1.feishu_message_responder)

            data =
              if is_function(responder, 1) do
                responder.(conn.query_params)
              else
                %{
                  "items" => Agent.get(__MODULE__, & &1.feishu_messages),
                  "has_more" => true,
                  "page_token" => "next-feishu-page"
                }
              end

            json(conn, 200, %{"code" => 0, "msg" => "ok", "data" => data})
          end

        {"GET", ["open-apis", "im", "v1", "messages", message_id]} ->
          conn = fetch_query_params(conn)

          record(%{
            kind: :feishu_get_message,
            message_id: message_id,
            query: conn.query_params,
            auth: conn |> get_req_header("authorization") |> List.first()
          })

          message =
            Agent.get(__MODULE__, & &1.feishu_messages)
            |> Enum.find(fn item -> item["message_id"] == message_id end)

          if message do
            json(conn, 200, %{"code" => 0, "msg" => "ok", "data" => %{"items" => [message]}})
          else
            json(conn, 200, %{"code" => 230_001, "msg" => "message not found"})
          end

        {"GET", ["open-apis", "im", "v1", "messages", message_id, "resources", file_key]} ->
          conn = fetch_query_params(conn)

          record(%{
            kind: :feishu_message_resource,
            message_id: message_id,
            file_key: file_key,
            query: conn.query_params,
            auth: conn |> get_req_header("authorization") |> List.first()
          })

          reject_token? =
            Agent.get_and_update(__MODULE__, fn state ->
              if state.feishu_token_rejections > 0 do
                {true, %{state | feishu_token_rejections: state.feishu_token_rejections - 1}}
              else
                {false, state}
              end
            end)

          if reject_token? do
            code =
              Agent.get(
                __MODULE__,
                &(&1.feishu_token_rejection_code || 99_991_677)
              )

            json(conn, 401, %{"code" => code, "msg" => "tenant access token expired"})
          else
            case Agent.get(__MODULE__, & &1.feishu_resource) do
              {:disconnect, headers, first_chunk} ->
                conn =
                  Enum.reduce(headers, conn, fn {name, value}, conn ->
                    put_resp_header(conn, name, value)
                  end)

                {:ok, conn} = conn |> send_chunked(200) |> chunk(first_chunk)

                raise Plug.Conn.WrapperError,
                  conn: conn,
                  kind: :error,
                  reason: :injected_disconnect

              {status, headers, body} ->
                conn =
                  Enum.reduce(headers, conn, fn {name, value}, conn ->
                    put_resp_header(conn, name, value)
                  end)

                send_resp(conn, status, body)
            end
          end

        {"PUT", ["open-apis", "im", "v1", "messages", message_id]} ->
          record(%{
            kind: :feishu_update_message,
            message_id: message_id,
            params: decode_request_body(raw)
          })

          json(conn, 200, %{"code" => 0, "msg" => "ok", "data" => %{}})

        {"PATCH", ["open-apis", "im", "v1", "messages", message_id]} ->
          params = decode_request_body(raw)
          record(%{kind: :feishu_patch_card, message_id: message_id, params: params})

          {status, body} =
            case Agent.get(__MODULE__, & &1.feishu_card_patch_responder) do
              nil -> {200, %{"code" => 0, "msg" => "ok", "data" => %{}}}
              responder -> responder.(%{message_id: message_id, params: params})
            end

          json(conn, status, body)

        {"DELETE", ["open-apis", "im", "v1", "messages", message_id]} ->
          record(%{kind: :feishu_delete_message, message_id: message_id})
          json(conn, 200, %{"code" => 0, "msg" => "ok", "data" => %{}})

        {"POST", ["open-apis", "im", "v1", "messages", message_id, "reactions"]} ->
          record(%{
            kind: :feishu_add_reaction,
            message_id: message_id,
            params: decode_request_body(raw)
          })

          json(conn, 200, %{
            "code" => 0,
            "msg" => "ok",
            "data" => %{"reaction_id" => "reaction-bot"}
          })

        {"GET", ["open-apis", "im", "v1", "messages", message_id, "reactions"]} ->
          conn = fetch_query_params(conn)

          record(%{
            kind: :feishu_list_reactions,
            message_id: message_id,
            query: conn.query_params
          })

          responder = Agent.get(__MODULE__, & &1.feishu_reaction_responder)

          data =
            if is_function(responder, 1) do
              responder.(conn.query_params)
            else
              %{
                "items" => Agent.get(__MODULE__, & &1.feishu_reactions),
                "has_more" => false,
                "page_token" => ""
              }
            end

          json(conn, 200, %{"code" => 0, "msg" => "ok", "data" => data})

        {"DELETE", ["open-apis", "im", "v1", "messages", message_id, "reactions", reaction_id]} ->
          record(%{
            kind: :feishu_remove_reaction,
            message_id: message_id,
            reaction_id: reaction_id
          })

          json(conn, 200, %{"code" => 0, "msg" => "ok", "data" => %{}})

        {"POST", ["open-apis", "im", "v1", "pins"]} ->
          record(%{kind: :feishu_pin, params: decode_request_body(raw)})
          json(conn, 200, %{"code" => 0, "msg" => "ok", "data" => %{}})

        {"DELETE", ["open-apis", "im", "v1", "pins", message_id]} ->
          record(%{kind: :feishu_unpin, message_id: message_id})
          json(conn, 200, %{"code" => 0, "msg" => "ok", "data" => %{}})

        {"GET", ["open-apis", "im", "v1", "pins"]} ->
          conn = fetch_query_params(conn)
          record(%{kind: :feishu_list_pins, query: conn.query_params})

          json(conn, 200, %{
            "code" => 0,
            "msg" => "ok",
            "data" => %{"items" => [%{"message_id" => "om_pin"}], "has_more" => false}
          })

        {"GET", ["open-apis", "im", "v1", "chats", chat_id, "members"]} ->
          conn = fetch_query_params(conn)
          record(%{kind: :feishu_list_chat_members, chat_id: chat_id, query: conn.query_params})

          data =
            case Agent.get(__MODULE__, & &1.feishu_chat_members_responder) do
              responder when is_function(responder, 1) ->
                responder.(conn.query_params)

              _ ->
                %{
                  "items" => [%{"member_id" => "ou_alice", "name" => "Alice"}],
                  "has_more" => false
                }
            end

          json(conn, 200, %{
            "code" => 0,
            "msg" => "ok",
            "data" => data
          })

        {"GET", ["open-apis", "im", "v1", "chats", chat_id]} ->
          record(%{
            kind: :feishu_get_chat,
            chat_id: chat_id,
            auth: conn |> get_req_header("authorization") |> List.first()
          })

          json(conn, 200, %{
            "code" => 0,
            "msg" => "ok",
            "data" => %{
              "chat_id" => chat_id,
              "chat_type" => "group",
              "member_count" => 2,
              "owner_id" => "ou_owner"
            }
          })

        {"GET", ["open-apis", "contact", "v3", "departments", department_id, "children"]} ->
          conn = fetch_query_params(conn)

          record(%{
            kind: :feishu_list_departments,
            department_id: department_id,
            query: conn.query_params
          })

          json(conn, 200, %{
            "code" => 0,
            "msg" => "ok",
            "data" => %{
              "items" => [
                %{"open_department_id" => "od_engineering", "name" => "Engineering"}
              ],
              "has_more" => false
            }
          })

        {"GET", ["open-apis", "contact", "v3", "scopes"]} ->
          conn = fetch_query_params(conn)
          record(%{kind: :feishu_list_contact_scopes, query: conn.query_params})

          json(conn, 200, %{
            "code" => 0,
            "msg" => "ok",
            "data" => %{
              "department_ids" => ["od_engineering"],
              "user_ids" => ["ou_explicit"],
              "group_ids" => ["ug_oncall"],
              "has_more" => true,
              "page_token" => "contact-scope-page-2"
            }
          })

        {"GET", ["open-apis", "contact", "v3", "users", "find_by_department"]} ->
          conn = fetch_query_params(conn)

          record(%{kind: :feishu_list_department_users, query: conn.query_params})

          json(conn, 200, %{
            "code" => 0,
            "msg" => "ok",
            "data" => %{
              "items" => [%{"open_id" => "ou_alice", "name" => "Alice"}],
              "has_more" => false
            }
          })

        {"GET", ["open-apis", "contact", "v3", "users", user_id]} ->
          conn = fetch_query_params(conn)
          record(%{kind: :feishu_get_user, user_id: user_id, query: conn.query_params})

          json(conn, 200, %{
            "code" => 0,
            "msg" => "ok",
            "data" => %{
              "user" => %{
                "open_id" => user_id,
                "name" => "Alice",
                "email" => "alice@example.com"
              }
            }
          })

        _ ->
          json(conn, 404, %{"error" => "not_found"})
      end
    end

    defp record(req) do
      waiters =
        Agent.get_and_update(__MODULE__, fn s ->
          {ready, waiting} =
            Enum.split_with(Map.get(s, :request_waiters, []), fn {token, _pid} ->
              req[:kind] == :telegram and req[:token] == token
            end)

          {ready, %{s | requests: [req | s.requests]} |> Map.put(:request_waiters, waiting)}
        end)

      Enum.each(waiters, fn {_token, pid} ->
        SystemsRuntime.Proc.send(pid, {__MODULE__, :request_seen})
      end)
    end

    defp read_full_body(conn, chunks \\ []) do
      case read_body(conn, length: 32 * 1024 * 1024, read_length: 1024 * 1024) do
        {:more, chunk, conn} ->
          read_full_body(conn, [chunk | chunks])

        {:ok, chunk, conn} ->
          {:ok, chunks |> Enum.reverse([chunk]) |> IO.iodata_to_binary(), conn}
      end
    end

    defp json(conn, status, body) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(body))
    end

    defp decode_request_body(raw) do
      case Jason.decode(raw) do
        {:ok, params} when is_map(params) -> params
        _ -> URI.decode_query(raw)
      end
    end
  end

  defmodule FakeAgentDelivery do
    @moduledoc false
    @behaviour SalixIM.Ports.AgentDelivery
    @behaviour SalixIM.Ports.SessionActivity

    @impl true
    def notify_conversation(agent, source),
      do: SalixIM.TestSupport.ConversationDelivery.notify(__MODULE__, agent, source)

    @impl true
    def conversation_progress(_, _, participant),
      do: SalixStore.CasRecord.get("test/conversation-delivery/#{participant}")

    def deliver(agent_id, payload, opts) do
      if pid = SystemsRuntime.get_env(:salix_im, :fake_agent_delivery_test_pid) do
        SystemsRuntime.Proc.send(pid, {:agent_delivery, agent_id, payload, opts})
      end

      {:ok, :created}
    end

    @impl true
    def get_session(_agent_id, "ses1_1100000000000000033", _opts) do
      {:ok,
       %{
         "runtime_kind" => "internal",
         "status" => "mystery",
         "activity_status" => "mystery",
         "messages" => [],
         "async_tool_calls" => %{},
         "created_at" => 1_780_000_000,
         "updated_at" => 1_780_000_014
       }}
    end

    def get_session(_agent_id, "ses1_1100000000000000032", _opts),
      do: {:error, :temporarily_unavailable}

    def get_session(_agent_id, _session_id, _opts), do: {:error, :not_found}

    @impl true
    def get(agent_id, session_id) do
      case get_session(agent_id, session_id, []) do
        {:ok, session} ->
          {:ok,
           session
           |> Map.put("session_id", session_id)
           |> SalixAgent.SessionActivity.project()}

        {:error, _reason} = error ->
          error
      end
    end

    @impl true
    def subscribe(_agent_id, _session_id), do: :ok

    @impl true
    def unsubscribe(_agent_id, _session_id), do: :ok

    @impl true
    def get_session_messages(agent_id, session_id), do: get_session(agent_id, session_id, [])
  end

  defmodule HeldContextAgentDelivery do
    @moduledoc false
    @behaviour SalixIM.Ports.AgentDelivery

    @impl true
    def notify_conversation(agent, source),
      do: SalixIM.TestSupport.ConversationDelivery.notify(__MODULE__, agent, source)

    def deliver(agent_id, payload, opts) do
      if String.contains?(opts[:source_message_id] || "", "Ev-first-context-concurrent-mention") do
        if pid = SystemsRuntime.get_env(:salix_im, :fake_agent_delivery_test_pid) do
          SystemsRuntime.Proc.send(
            pid,
            {:held_context_delivery_started, SystemsRuntime.Proc.self()}
          )
        end

        SystemsRuntime.Proc.receive do
          :release_context_delivery -> :ok
        end
      end

      FakeAgentDelivery.deliver(agent_id, payload, opts)
    end

    @impl true
    def get_session(agent_id, session_id, opts),
      do: FakeAgentDelivery.get_session(agent_id, session_id, opts)

    @impl true
    def get_session_messages(agent_id, session_id),
      do: FakeAgentDelivery.get_session_messages(agent_id, session_id)
  end

  defmodule RecordingTaskCreate do
    @moduledoc false
    @behaviour SalixIM.Ports.TaskCreate

    def set_owner(pid), do: SystemsRuntime.PersistentTerm.put({__MODULE__, :owner}, pid)

    @impl true
    def create_task_conversation(group_id, delegator_agent_id, target_agent_id, attrs) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.PersistentTerm.get({__MODULE__, :owner}),
        {:task_create, group_id, delegator_agent_id, target_agent_id, attrs}
      )

      {:ok,
       %{
         "conversation_id" => SalixStore.Ids.new_conversation_id(),
         "message_id" => SalixStore.Ids.new_message_id(),
         "delivery_status" => "queued",
         "inserted" => true,
         "conversation" => %{"status" => "active"}
       }}
    end

    # The product's check: one model id stands for a product without a model choice.
    @impl true
    def session_model(_scope, %{"model" => "unsupported"}),
      do: {:error, :model_selection_unsupported}

    def session_model(scope, choice) do
      checked = Map.put(choice, "checked", true)

      if scope[:worker_runtime],
        do: {:ok, Map.put(checked, "worker_runtime", scope.worker_runtime)},
        else: {:ok, checked}
    end

    # The product resolves where a Task runs; one device id stands for an offline station.
    @impl true
    def runs_on(_scope, %{"kind" => "station", "device_id" => "offline"}),
      do: {:error, :device_offline}

    # Devices that cannot take Tasks: the old connector, an outdated station.
    def runs_on(_scope, %{"kind" => "station", "device_id" => "old-connector"}),
      do: {:error, {:device_needs_station, SalixStore.StationReadiness.refusal(%{})}}

    def runs_on(_scope, %{"kind" => "station", "device_id" => "outdated"}),
      do: {:error, {:station_outdated, SalixStore.StationReadiness.refusal(%{"tasks" => 1})}}

    def runs_on(scope, %{"kind" => "cloud_vm"}),
      do: {:ok, %{"kind" => "cloud_vm", "device_id" => "dev-cloudvm-" <> scope.group_id}}

    # The product's one Worker for the Group, when a test names it.
    @impl true
    def task_worker(_scope) do
      case SystemsRuntime.PersistentTerm.get({__MODULE__, :task_worker}, nil) do
        nil -> {:error, :task_worker_required}
        agent_id -> {:ok, agent_id}
      end
    end
  end

  defmodule RecordingTaskSchedule do
    @moduledoc false
    @behaviour SalixIM.Ports.TaskSchedule

    def set_owner(pid), do: SystemsRuntime.PersistentTerm.put({__MODULE__, :owner}, pid)

    @impl true
    def update_task_schedule(group_id, conversation_id, schedule) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.PersistentTerm.get({__MODULE__, :owner}),
        {:task_schedule_update, group_id, conversation_id, schedule}
      )

      schedule =
        case schedule do
          nil -> %{"schedule_id" => nil, "command" => "preserved command"}
          attrs -> Map.put_new(attrs, "schedule_id", "sch1_provider_test")
        end

      {:ok, %{"conversation_id" => conversation_id, "schedule" => schedule}}
    end
  end

  defmodule MockComposioStore do
    @moduledoc false
    @behaviour SalixAgent.ComposioStore

    @impl true
    def settings(_tenant), do: {:ok, %{"api_key" => "ck_provider_e2e"}}
  end

  defmodule MockComposioClient do
    @moduledoc false
    use Elixir.Agent

    def start_link(_opts \\ []) do
      Agent.start_link(
        fn -> %{accounts: [], execute_results: %{}, requests: []} end,
        name: __MODULE__
      )
    end

    def configure(accounts, execute_results) do
      Agent.update(__MODULE__, fn state ->
        %{state | accounts: accounts, execute_results: execute_results, requests: []}
      end)
    end

    def requests do
      Agent.get(__MODULE__, &Enum.reverse(&1.requests))
    end

    def list_connected_accounts_all(settings, user_id, opts) do
      record({:list_connected_accounts_all, settings, user_id, opts})
      {:ok, Agent.get(__MODULE__, & &1.accounts)}
    end

    def get_connected_account(settings, account_id) do
      record({:get_connected_account, settings, account_id})

      case Agent.get(
             __MODULE__,
             &Enum.find(&1.accounts, fn account -> account["id"] == account_id end)
           ) do
        nil -> {:error, :not_found}
        account -> {:ok, account}
      end
    end

    def list_tools(settings, opts) do
      record({:list_tools, settings, opts})
      slug = to_string(opts[:tool_slugs] || "")

      {:ok,
       [
         %{
           "slug" => slug,
           "name" => slug,
           "description" => "calendar test tool",
           "toolkit" => %{"slug" => "googlecalendar"},
           "input_parameters" => %{"type" => "object"}
         }
       ]}
    end

    def execute_tool(settings, tool_slug, user_id, arguments, opts) do
      record({:execute_tool, settings, tool_slug, user_id, arguments, opts})

      Agent.get(__MODULE__, fn state ->
        Map.fetch!(state.execute_results, tool_slug)
      end)
    end

    defp record(request) do
      Agent.update(__MODULE__, &%{&1 | requests: [request | &1.requests]})
    end
  end

  defmodule CalendarParityLLM do
    @moduledoc false
    @behaviour SalixAgent.LLM

    alias SalixIM.FeishuCalendarContract

    def configure(config), do: SystemsRuntime.PersistentTerm.put({__MODULE__, :config}, config)
    def clear, do: SystemsRuntime.PersistentTerm.erase({__MODULE__, :config})

    @impl true
    def complete(messages, _tools) do
      config = SystemsRuntime.PersistentTerm.get({__MODULE__, :config})
      prompt = Enum.map_join(messages, "\n", &message_content/1)

      case latest_turn(messages) do
        :user ->
          if prompt_has?(prompt, FeishuCalendarContract.notification_clause()) and
               not String.contains?(prompt, "meeting.get_calendar_policy") do
            call("calendar-connections", "composio.list_connections", %{})
          else
            {:final, "calendar parity prompt rejected"}
          end

        {:tool, "calendar-connections", content} ->
          case active_calendar_accounts(content) do
            [%{"connected_account_id" => connected_account_id}] ->
              if connected_account_id == config.connected_account_id do
                call("calendar-attendee", "im_api.feishu.get_user", %{
                  "connect_id" => config.connect_id,
                  "user_id" => "ou_alice"
                })
              else
                {:final, "unexpected Calendar account"}
              end

            accounts when length(accounts) > 1 ->
              ids = Enum.map_join(accounts, " 和 ", & &1["connected_account_id"])

              if prompt_has?(prompt, FeishuCalendarContract.account_selection_clause()) do
                call("calendar-choice-reply", "im_api.feishu.reply_text", %{
                  "connect_id" => config.connect_id,
                  "message_id" => config.message_id,
                  "chat_id" => config.chat_id,
                  "chat_type" => "group",
                  "reply_in_thread" => true,
                  "text" => "发现多个 ACTIVE Google Calendar 连接：#{ids}。请选择一个；确认前没有创建日程。"
                })
              else
                {:final, "Calendar account-selection prompt contract missing"}
              end

            _ ->
              {:final, "no ACTIVE Google Calendar account"}
          end

        {:tool, "calendar-attendee", content} ->
          if String.contains?(content, config.attendee_email) do
            call("calendar-create-schema", "composio.get_tool", %{
              "tool_slug" => "GOOGLECALENDAR_CREATE_EVENT"
            })
          else
            {:final, "attendee email missing"}
          end

        {:tool, "calendar-create-schema", content} ->
          if String.contains?(content, "GOOGLECALENDAR_CREATE_EVENT") and
               prompt_has?(prompt, FeishuCalendarContract.account_pinning_clause()) do
            call("calendar-create", "composio.execute", %{
              "tool_slug" => "GOOGLECALENDAR_CREATE_EVENT",
              "connected_account_id" => config.connected_account_id,
              "arguments" => config.create_arguments
            })
          else
            {:final, "Calendar create schema missing"}
          end

        {:tool, "calendar-create", content} ->
          case decoded_content(content) do
            %{"successful" => true, "data" => %{"id" => event_id}} ->
              configure(Map.put(config, :event_id, event_id))

              if prompt_has?(prompt, FeishuCalendarContract.readback_clause()) do
                call("calendar-readback-schema", "composio.get_tool", %{
                  "tool_slug" => "GOOGLECALENDAR_GET_EVENT"
                })
              else
                {:final, "Calendar exact-readback prompt contract missing"}
              end

            _ ->
              {:final, "Calendar create did not return an event"}
          end

        {:tool, "calendar-readback-schema", content} ->
          if String.contains?(content, "GOOGLECALENDAR_GET_EVENT") do
            config = SystemsRuntime.PersistentTerm.get({__MODULE__, :config})

            call("calendar-readback", "composio.execute", %{
              "tool_slug" => "GOOGLECALENDAR_GET_EVENT",
              "connected_account_id" => config.connected_account_id,
              "arguments" => %{
                "calendar_id" => config.calendar_id,
                "event_id" => config.event_id
              }
            })
          else
            {:final, "Calendar readback schema missing"}
          end

        {:tool, "calendar-readback", content} ->
          if verified_event?(decoded_content(content), config) do
            call("calendar-confirmation", "im_api.feishu.reply_text", %{
              "connect_id" => config.connect_id,
              "message_id" => config.message_id,
              "chat_id" => config.chat_id,
              "chat_type" => "group",
              "reply_in_thread" => true,
              "text" =>
                "已验证创建#{config.summary}：#{config.start_at}，日历 #{config.calendar_id}，参会人 #{config.attendee_email}，Google Meet #{config.meet_url}。"
            })
          else
            call("calendar-verification-failed", "im_api.feishu.reply_text", %{
              "connect_id" => config.connect_id,
              "message_id" => config.message_id,
              "chat_id" => config.chat_id,
              "chat_type" => "group",
              "reply_in_thread" => true,
              "text" => "日程创建后的读回结果不一致，未确认创建成功。"
            })
          end

        {:tool, id, _content}
        when id in [
               "calendar-choice-reply",
               "calendar-confirmation",
               "calendar-verification-failed"
             ] ->
          {:final, "done"}

        _ ->
          {:final, "unexpected Calendar parity turn"}
      end
    end

    defp latest_turn(messages) do
      # Context notices accompany an input; they do not replace its business turn.
      messages =
        Enum.reject(messages, fn message ->
          (message[:content_kind] || message["content_kind"]) == "model_context" or
            (message[:role] || message["role"]) in ["system", "summary"]
        end)

      case List.last(messages) do
        %{role: "tool", tool_call_id: id, content: content} ->
          {:tool, id, to_string(content)}

        %{"role" => "tool", "tool_call_id" => id, "content" => content} ->
          {:tool, id, to_string(content)}

        message when is_map(message) ->
          case runtime_tool_terminal(message) do
            {:ok, id, content} -> {:tool, id, content}
            :error -> latest_non_tool_turn(message)
          end

        _ ->
          :other
      end
    end

    defp runtime_tool_terminal(message) do
      role = Map.get(message, :role) || Map.get(message, "role")
      type = Map.get(message, :type) || Map.get(message, "type")

      source_tool_call_id =
        Map.get(message, :source_tool_call_id) || Map.get(message, "source_tool_call_id")

      content = Map.get(message, :content) || Map.get(message, "content")

      with "runtime" <- role,
           true <- type in ["tool_call_completed", "tool_call_failed"],
           true <- is_binary(source_tool_call_id) and source_tool_call_id != "",
           true <- is_binary(content),
           {:ok, payload} when is_map(payload) <-
             Jason.decode(String.replace(content, ~r/^\[src:a-[^\]\n]+\]\n/, "")),
           {:ok, result_content} <- result_content(payload) do
        {:ok, source_tool_call_id, result_content}
      else
        _ -> :error
      end
    end

    defp latest_non_tool_turn(message) do
      case Map.get(message, :role) || Map.get(message, "role") do
        "user" -> :user
        _ -> :other
      end
    end

    defp result_content(%{"result" => %{"content" => content}}) when is_binary(content),
      do: {:ok, content}

    defp result_content(%{"result_page" => %{"content" => content}}) when is_binary(content),
      do: {:ok, content}

    defp result_content(_payload), do: :error

    defp active_calendar_accounts(content) do
      case decoded_content(content) do
        %{"connections" => connections} when is_list(connections) ->
          Enum.filter(connections, fn account ->
            account["toolkit"] == "googlecalendar" and account["status"] == "ACTIVE"
          end)

        _ ->
          []
      end
    end

    defp verified_event?(%{"successful" => true, "data" => data}, config) do
      data["id"] == config.event_id and
        data["calendar_id"] == config.calendar_id and
        data["summary"] == config.summary and
        get_in(data, ["start", "dateTime"]) == config.start_at and
        get_in(data, ["start", "timeZone"]) == config.timezone and
        get_in(data, ["end", "dateTime"]) == config.end_at and
        Enum.any?(data["attendees"] || [], &(&1["email"] == config.attendee_email)) and
        data["hangoutLink"] == config.meet_url
    end

    defp verified_event?(_payload, _config), do: false

    defp decoded_content(content) do
      case Jason.decode(content) do
        {:ok, %{"content" => nested}} when is_binary(nested) -> decoded_content(nested)
        {:ok, decoded} -> decoded
        _ -> %{}
      end
    end

    defp message_content(message), do: to_string(message[:content] || message["content"] || "")

    defp prompt_has?(prompt, clause), do: String.contains?(prompt, clause)

    defp call(id, tool, params) do
      {:assistant, "", [%{id: id, name: "call", args: %{"tool" => tool, "params" => params}}]}
    end
  end

  defmodule RouterTaskCardLLM do
    @moduledoc false
    @behaviour SalixAgent.LLM

    def configure(config), do: SystemsRuntime.PersistentTerm.put({__MODULE__, :config}, config)
    def clear, do: SystemsRuntime.PersistentTerm.erase({__MODULE__, :config})

    @impl true
    def complete(messages, _tools) do
      config = SystemsRuntime.PersistentTerm.get({__MODULE__, :config})

      if router_turn?(messages, config.marker) do
        case latest_tool_terminal(messages) do
          {"router-task-create", _content} when config.channel == nil ->
            {:final, "Task created."}

          {"router-task-create", content} ->
            %{"conversation_id" => conversation_id} = decode_result(content)

            call("router-task-card", "im_api.slack.post_task_card", %{
              "connect_id" => config.connect_id,
              "conversation_id" => conversation_id,
              "channel" => config.channel,
              "thread_ts" => config.thread_ts
            })

          {"router-task-card", _content} ->
            {:final, "Task card published."}

          nil ->
            call("router-task-create", "im_api.internal.task.create", %{
              "connect_id" => "internal",
              "agent_id" => config.worker_id,
              "content" => "Prepare a short repository health report.",
              "title" => "Repository health report"
            })

          {_unexpected_tool, _content} ->
            {:final, "Unexpected tool result."}
        end
      else
        {:final, "Worker acknowledged the Task."}
      end
    end

    @impl true
    def complete_stream(messages, tools, _on_delta), do: complete(messages, tools)

    @impl true
    def complete_stream(messages, tools, _on_delta, _opts), do: complete(messages, tools)

    defp router_turn?(messages, marker) do
      Enum.any?(messages, fn message ->
        message
        |> message_content()
        |> String.contains?(marker)
      end)
    end

    defp latest_tool_terminal(messages) do
      messages
      |> Enum.reverse()
      |> Enum.find_value(fn message ->
        role = Map.get(message, :role) || Map.get(message, "role")
        tool_call_id = Map.get(message, :tool_call_id) || Map.get(message, "tool_call_id")

        source_tool_call_id =
          Map.get(message, :source_tool_call_id) || Map.get(message, "source_tool_call_id")

        type = Map.get(message, :type) || Map.get(message, "type")
        content = message_content(message)

        cond do
          role == "tool" and is_binary(tool_call_id) ->
            {tool_call_id, content}

          role == "runtime" and type in ["tool_call_completed", "tool_call_failed"] and
              is_binary(source_tool_call_id) ->
            with {:ok, payload} when is_map(payload) <-
                   Jason.decode(String.replace(content, ~r/^\[src:a-[^\]\n]+\]\n/, "")),
                 result when is_map(result) <- payload["result"] || payload["result_page"],
                 result_content when is_binary(result_content) <- result["content"] do
              {source_tool_call_id, result_content}
            else
              _ -> nil
            end

          true ->
            nil
        end
      end)
    end

    defp decode_result(content) do
      case Jason.decode(content) do
        {:ok, %{"content" => nested}} when is_binary(nested) -> decode_result(nested)
        {:ok, result} when is_map(result) -> result
      end
    end

    defp message_content(message),
      do: to_string(Map.get(message, :content) || Map.get(message, "content") || "")

    defp call(id, tool, params) do
      {:assistant, "", [%{id: id, name: "call", args: %{"tool" => tool, "params" => params}}]}
    end
  end

  defmodule ChannelCreatedJoinLLM do
    @moduledoc false
    @behaviour SalixAgent.LLM

    def configure(config), do: SystemsRuntime.PersistentTerm.put({__MODULE__, :config}, config)
    def clear, do: SystemsRuntime.PersistentTerm.erase({__MODULE__, :config})

    @impl true
    def complete(messages, _tools) do
      config = SystemsRuntime.PersistentTerm.get({__MODULE__, :config})

      cond do
        called?(messages, "auto-join-channel") ->
          {:final, "joined"}

        prompt?(messages) ->
          {:assistant, "",
           [
             %{
               id: "auto-join-channel",
               name: "call",
               args: %{
                 "tool" => "im_api.slack.join_channel",
                 "params" => %{
                   "connect_id" => config.connect_id,
                   "channel" => config.channel_id
                 }
               }
             }
           ]}

        true ->
          {:final, "ack"}
      end
    end

    defp prompt?(messages) do
      Enum.any?(messages, fn message ->
        role = to_string(Map.get(message, :role) || Map.get(message, "role") || "")
        content = to_string(Map.get(message, :content) || Map.get(message, "content") || "")
        role == "user" and String.contains?(content, "new public channel was created")
      end)
    end

    defp called?(messages, id) do
      Enum.any?(messages, fn message ->
        Enum.any?(
          Map.get(message, :tool_calls) || Map.get(message, "tool_calls") || [],
          fn call ->
            to_string(Map.get(call, :id) || Map.get(call, "id") || "") == id
          end
        )
      end)
    end
  end

  setup do
    SalixIM.TestSupport.ProviderFixture.native_setup()
  end

  # put_env(key, nil) shadows get_env defaults — delete when prev was nil.
  defp restore(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore(app, key, value), do: SystemsRuntime.put_env(app, key, value)

  # Normal tools return immediately as async-running. Their authoritative
  # terminal value is therefore a runtime message correlated by the durable
  # envelope, while legacy/preflight terminal values can still be tool rows.
  defp tool_terminal_content(messages, tool_call_id) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn message ->
      role = Map.get(message, :role) || Map.get(message, "role")
      content = Map.get(message, :content) || Map.get(message, "content")

      cond do
        role == "tool" and
          (Map.get(message, :tool_call_id) || Map.get(message, "tool_call_id")) ==
            tool_call_id and is_binary(content) ->
          content

        role == "runtime" and
          (Map.get(message, :type) || Map.get(message, "type")) in [
            "tool_call_completed",
            "tool_call_failed"
          ] and
          (Map.get(message, :source_tool_call_id) ||
             Map.get(message, "source_tool_call_id")) == tool_call_id and
            is_binary(content) ->
          runtime_result_content(content)

        true ->
          nil
      end
    end)
  end

  defp runtime_result_content(content) do
    with {:ok, payload} when is_map(payload) <- Jason.decode(content) do
      case payload do
        %{"result" => %{"content" => result}} when is_binary(result) -> result
        %{"result_page" => %{"content" => result}} when is_binary(result) -> result
        _ -> nil
      end
    else
      _ -> nil
    end
  end

  defp put_conversation_links_config(tenant_id, template) do
    assert {:ok, _} =
             SalixStore.TenantConfigs.put(%{
               "tenant_id" => tenant_id,
               "name" => "conversation_links",
               "value" => %{"conversation_url_template" => template},
               "updated_at" => SystemsClock.system_time(:second)
             })
  end

  defp seed_group_conversation(group_id, agent_id, attrs) do
    now = SystemsClock.system_time(:millisecond)

    participants =
      attrs["participants"] ||
        [
          %{
            "actor_type" => "user",
            "user_id" => "current",
            "state" => "active",
            "notification_filter" => %{"messages" => "all", "statuses" => "none"},
            "created_at" => now,
            "updated_at" => now
          },
          %{
            "actor_type" => "agent",
            "agent_id" => agent_id,
            "role_label" => "agent",
            "state" => "active",
            "notification_filter" => %{"messages" => "all", "statuses" => "none"},
            "created_at" => now,
            "updated_at" => now
          }
        ]

    participants =
      participants
      |> Enum.with_index(1)
      |> Enum.map(fn {participant, index} ->
        participant
        |> Map.drop(["participant_id", "conversation_id"])
        |> put_provider_target_key(participant["participant_id"], index)
      end)

    conversation =
      %{
        "kind" => attrs["kind"] || "user_chat",
        "title" => attrs["title"] || "Conversation",
        "status" => "active",
        "activity_status" => "idle",
        "participants" => participants,
        "created_at" => now,
        "updated_at" => now
      }

    messages =
      attrs
      |> Map.get("messages", [])
      |> Enum.with_index(1)
      |> Enum.map(fn {message, index} ->
        request_identity =
          message["client_request_id"] || message["source_message_id"] ||
            message["idempotency_key"] || message["message_id"] ||
            "provider-test-seed-#{index}"

        message
        |> Map.drop(["message_id", "participant_id"])
        |> Map.put_new("kind", "message")
        |> Map.put_new("created_at", now)
        |> Map.put_new("source_message_id", request_identity)
      end)

    create_with_owner? = conversation["kind"] not in ["user_chat", "agent_task"]

    {conversation_id, append_messages?} =
      if create_with_owner? do
        create_attrs =
          attrs
          |> Map.drop(["conversation_id", "messages"])
          |> Map.merge(conversation)
          |> Map.update!("participants", fn participants ->
            Enum.map(participants, &drop_preallocated_session_identity/1)
          end)
          |> Map.put("source_refs", attrs["source_refs"])

        assert {:ok, created} =
                 SalixIM.ConversationInput.create_group_conversation(group_id, create_attrs)

        {created["conversation_id"], messages != []}
      else
        conversation_id = attrs["conversation_id"] || Ids.new_conversation_id()

        assert {:ok, seed} =
                 ConversationSeedInput.prepare(group_id, conversation_id, %{
                   "conversation" =>
                     if(Map.has_key?(attrs, "source_refs"),
                       do: Map.put(conversation, "source_refs", attrs["source_refs"]),
                       else: conversation
                     ),
                   "messages" => messages
                 })

        assert {:ok, _seeded} =
                 ConversationServer.seed_group_conversation_transcript(
                   group_id,
                   conversation_id,
                   seed
                 )

        {conversation_id, false}
      end

    if append_messages? do
      append_seed_messages!(
        group_id,
        conversation_id,
        attrs["participants"] || participants,
        attrs["messages"] || []
      )
    end

    {:ok, conversation} = Conversations.get_group_conversation(group_id, conversation_id)
    conversation
  end

  defp append_seed_messages!(group_id, conversation_id, source_participants, messages) do
    assert {:ok, %{"participants" => participants}} =
             Conversations.list_group_conversation_participants(
               group_id,
               conversation_id,
               limit: 1000
             )

    aliases =
      source_participants
      |> Enum.with_index()
      |> Map.new(fn {participant, index} ->
        {participant["participant_id"] || "participant-#{index}", participant}
      end)

    messages
    |> Enum.with_index(1)
    |> Enum.each(fn {message, index} ->
      source_participant = aliases[message["participant_id"]]
      participant = seed_message_participant!(participants, message, source_participant)

      request_identity =
        message["client_request_id"] || message["source_message_id"] ||
          message["idempotency_key"] || message["message_id"] ||
          "provider-test-seed-#{index}"

      attrs =
        message
        |> Map.drop(["message_id"])
        |> Map.put("participant_id", participant["participant_id"])
        |> Map.put_new("source_message_id", request_identity)

      assert {:ok, _message} =
               ConversationServer.append_group_conversation_message(
                 group_id,
                 conversation_id,
                 attrs
               )
    end)
  end

  defp seed_message_participant!(participants, message, source_participant) do
    actor_type = message["actor_type"] || "user"

    participant =
      Enum.find(participants, fn participant ->
        cond do
          is_map(source_participant) ->
            same_seed_participant?(participant, source_participant)

          actor_type == "agent" ->
            participant["actor_type"] == "agent" and
              participant["agent_id"] == message["agent_id"]

          actor_type in ["provider_user", "provider_system"] ->
            participant["actor_type"] == "provider" and
              message["provider"] in [nil, "", participant["provider"]]

          true ->
            participant["actor_type"] == "user" and
              (message["user_id"] || "current") == (participant["user_id"] || "current")
        end
      end)

    assert participant
    participant
  end

  defp same_seed_participant?(participant, source) do
    case source["actor_type"] do
      "agent" ->
        participant["actor_type"] == "agent" and
          participant["agent_id"] == source["agent_id"] and
          get_in(participant, ["payload", "session_id"]) ==
            get_in(source, ["payload", "session_id"])

      "user" ->
        participant["actor_type"] == "user" and
          (participant["user_id"] || "current") == (source["user_id"] || "current")

      "provider" ->
        participant["actor_type"] == "provider" and
          participant["provider"] == source["provider"] and
          participant["target_key"] ==
            (source["target_key"] || source["participant_id"])
    end
  end

  defp put_provider_target_key(%{"actor_type" => "provider"} = participant, source_id, index) do
    case participant["target_key"] do
      target_key when is_binary(target_key) and target_key != "" ->
        participant

      _ ->
        Map.put(
          participant,
          "target_key",
          source_id || "provider-test-target-#{index}"
        )
    end
  end

  defp put_provider_target_key(participant, _source_id, _index), do: participant

  defp drop_preallocated_session_identity(%{"actor_type" => "agent"} = participant) do
    Map.update(participant, "payload", %{}, &Map.delete(&1, "session_id"))
  end

  defp drop_preallocated_session_identity(participant), do: participant

  defp agent_participant(conversation_id, agent_id, participant_id, session_id, attrs \\ %{}) do
    now = SystemsClock.system_time(:millisecond)

    participant =
      %{
        "participant_id" => participant_id,
        "conversation_id" => conversation_id,
        "actor_type" => "agent",
        "agent_id" => agent_id,
        "role_label" => "agent",
        "state" => "active",
        "notification_filter" => %{"messages" => "all", "statuses" => "none"},
        "created_at" => now,
        "updated_at" => now
      }

    participant =
      if session_id != "" and not Map.has_key?(attrs, "payload") do
        Map.put(participant, "payload", %{"session_id" => session_id})
      else
        participant
      end

    Map.merge(participant, attrs)
  end

  defp participant_id_for_session!(group_id, conversation_id, session_id) do
    {:ok, %{"participants" => participants}} =
      Conversations.list_group_conversation_participants(group_id, conversation_id)

    participant =
      Enum.find(participants, &(get_in(&1, ["payload", "session_id"]) == session_id))

    participant["participant_id"]
  end

  defp participant_id_for_actor!(group_id, conversation_id, actor_type) do
    {:ok, %{"participants" => participants}} =
      Conversations.list_group_conversation_participants(group_id, conversation_id)

    participant = Enum.find(participants, &(&1["actor_type"] == actor_type))
    participant["participant_id"]
  end

  defp participant_id_for_agent!(group_id, conversation_id, agent_id) do
    {:ok, %{"participants" => participants}} =
      Conversations.list_group_conversation_participants(group_id, conversation_id)

    participant = Enum.find(participants, &(&1["agent_id"] == agent_id))
    participant["participant_id"]
  end

  defp create_test_agent!(tenant_id, group_id, _agent_id, name),
    do:
      SalixAgent.TestSupport.create_control_agent_in_group!(tenant_id, group_id, %{
        "name" => name,
        "role" => "worker"
      })

  defp task_card_participant!(group_id, conversation_id) do
    assert {:ok, %{"participants" => participants}} =
             Conversations.list_group_conversation_participants(group_id, conversation_id,
               limit: 100
             )

    assert participant =
             Enum.find(participants, fn participant ->
               participant["actor_type"] == "provider" and
                 participant["provider"] == "slack" and
                 get_in(participant, ["payload", "projection"]) == "slack_task_card"
             end)

    participant
  end

  defp feishu_task_card_participant!(group_id, conversation_id) do
    assert {:ok, %{"participants" => participants}} =
             Conversations.list_group_conversation_participants(group_id, conversation_id,
               limit: 100
             )

    assert participant =
             Enum.find(participants, fn participant ->
               participant["provider"] == "feishu" and
                 get_in(participant, ["payload", "projection"]) == "feishu_task_card"
             end)

    participant
  end

  defp feishu_card_status(card),
    do: get_in(card, ["header", "text_tag_list", Access.at(0), "text", "content"])

  defp feishu_card_text(card),
    do: Enum.map(get_in(card, ["body", "elements"]) || [], & &1["content"])

  defp active_provider_receipts(store) do
    owner = SystemsRuntime.Server.get_state(store, :infinity)

    prefix =
      Keys.ctl_group_conversation_participant_deliveries_prefix(
        owner.group_id,
        owner.conversation_id,
        owner.participant_id
      )

    {:ok, objects} = SalixStore.S3.list_all(prefix)

    records =
      for %{key: key} <- objects,
          String.ends_with?(key, "/state.json"),
          {:ok, %{body: body, etag: revision}} = SalixStore.S3.get(key),
          record = Jason.decode!(body),
          record["status"] in ~w(pending delivering retry_waiting),
          do: {record["delivery_id"], record, revision}

    {:ok, records}
  end

  defp slack_task_card_from_request(request) do
    assert [card] =
             request.params["blocks"]
             |> Jason.decode!()
             |> Enum.filter(&(&1["type"] == "task_card"))

    card
  end

  defp conversation_link_card?(request, title, url) do
    case Jason.decode!(request.params["blocks"]) do
      [
        %{
          "type" => "card",
          "block_id" => block_id,
          "title" => %{"type" => "mrkdwn", "text" => ^title},
          "subtitle" => %{"type" => "mrkdwn", "text" => "Bridge for Teams"},
          "body" => %{
            "type" => "mrkdwn",
            "text" => "This Slack thread is connected to the Task."
          },
          "actions" => [
            %{
              "type" => "button",
              "action_id" => "open_task",
              "text" => %{"type" => "plain_text", "text" => "Open Task"},
              "url" => ^url
            }
          ]
        }
      ] ->
        is_binary(block_id) and block_id != ""

      _blocks ->
        false
    end
  end

  defp emit_task_card_metadata!(method, message_ts, opts \\ []) do
    assert {:ok, :accepted} = task_card_metadata_result(method, message_ts, opts)
    :ok
  end

  defp task_card_metadata_result(method, message_ts, opts) do
    request = MockSlack.last_request(method)
    task_card_metadata_result_for_request(request, message_ts, opts)
  end

  defp task_card_metadata_result_for_request(request, message_ts, opts) do
    metadata = Jason.decode!(request.params["metadata"])

    metadata =
      case opts[:block_id] do
        nil -> metadata
        block_id -> put_in(metadata, ["event_payload", "block_id"], block_id)
      end

    kind = opts[:kind] || "message_metadata_posted"

    event = %{
      "type" => kind,
      "app_id" => "A1",
      "channel_id" => request.params["channel"],
      "message_ts" => message_ts,
      "event_ts" => "#{SystemsClock.system_time(:second)}.000001"
    }

    event =
      if kind == "message_metadata_deleted",
        do: Map.put(event, "previous_metadata", metadata),
        else: Map.put(event, "metadata", metadata)

    envelope = %{
      "type" => "event_callback",
      "api_app_id" => "A1",
      "team_id" => "T1",
      "event_id" => "Ev-task-card-#{SystemsRuntime.Proc.unique_integer([:positive, :monotonic])}",
      "event_time" => SystemsClock.system_time(:second),
      "event" => event
    }

    raw = Jason.encode!(envelope)

    SalixIM.ProviderHTTP.handle_slack_request(
      "A1",
      envelope,
      sign_slack_body(raw, "task-card-signing-secret"),
      raw
    )
  end

  defp slack_task_card_output(card),
    do: card |> Map.get("output") |> slack_rich_text_plain()

  defp slack_task_card_details(card),
    do: card |> Map.get("details") |> slack_rich_text_plain()

  defp slack_rich_text_plain(%{"elements" => elements}) when is_list(elements) do
    Enum.map_join(elements, "\n\n", &slack_rich_text_element_plain/1)
  end

  defp slack_rich_text_plain(_rich_text), do: nil

  defp slack_rich_text_element_plain(%{"type" => "rich_text_list", "elements" => elements}) do
    Enum.map_join(elements, "\n", &slack_rich_text_element_plain/1)
  end

  defp slack_rich_text_element_plain(%{"elements" => elements}) when is_list(elements) do
    Enum.map_join(elements, "", fn
      %{"text" => text} when is_binary(text) -> text
      element -> slack_rich_text_element_plain(element)
    end)
  end

  defp slack_rich_text_element_plain(%{"text" => text}) when is_binary(text), do: text
  defp slack_rich_text_element_plain(_element), do: ""

  defp refute_private_participant_fields(participant) do
    Enum.each(
      ~w(agent_id user_id role_label state notification_filter payload activity_status session_id env_id codex_thread_id),
      &refute(Map.has_key?(participant, &1))
    )
  end

  defp refute_status_private_fields(status) do
    Enum.each(
      ~w(agent_id session_id runtime_kind runtime_provider status messages events async_tool_calls last_accepted_message_id next_message_id env_id agent_runtime_id process_name codex_thread_id last_error payload raw_error trace runtime_environment_status),
      &refute(Map.has_key?(status, &1))
    )

    refute Map.has_key?(status["activity"] || %{}, "kind")
    refute Map.has_key?(status["activity"] || %{}, "description")
    refute Map.has_key?(status["wait"] || %{}, "wait_id")
    refute Map.has_key?(status["wait"] || %{}, "tool_call_id")
    refute Map.has_key?(status["wait"] || %{}, "tool_call_ids")
  end

  defp delivery_records(group_id, conversation_id) do
    assert {:ok, %{"deliveries" => deliveries}} =
             Conversations.group_conversation_delivery_status(
               group_id,
               conversation_id,
               limit: 1000
             )

    Map.new(deliveries, fn delivery ->
      rec =
        delivery
        |> Map.delete("delivery")
        |> Map.merge(delivery["delivery"] || %{})

      {delivery["delivery_id"], rec}
    end)
  end

  defp agent_task_conversation!(group_id) do
    assert eventually(fn ->
             case Conversations.list_group_conversations(group_id, limit: 10) do
               {:ok, %{"data" => conversations}} ->
                 Enum.any?(conversations, &(&1["kind"] == "agent_task"))

               _ ->
                 false
             end
           end)

    assert {:ok, %{"data" => conversations}} =
             Conversations.list_group_conversations(group_id, limit: 10)

    assert conversation = Enum.find(conversations, &(&1["kind"] == "agent_task"))
    conversation
  end

  defp delivery_key(group_id, conversation_id, message_id, participant_id) do
    Keys.ctl_group_conversation_participant_delivery_state(
      group_id,
      conversation_id,
      participant_id,
      Enum.join([group_id, conversation_id, message_id, participant_id], ":")
    )
  end

  defp put_delivery!(group_id, conversation_id, participant_id, delivery) do
    participant =
      case Conversations.get_group_conversation_participant(
             group_id,
             conversation_id,
             participant_id
           ) do
        {:ok, participant} ->
          participant

        {:error, :not_found} ->
          assert {:ok, participant} =
                   ConversationServer.ensure_group_conversation_provider_participant(
                     group_id,
                     conversation_id,
                     %{
                       "actor_type" => "provider",
                       "provider" => delivery["participant_provider"],
                       "target_key" => participant_id,
                       "role_label" => delivery["participant_role_label"] || "delivery_target",
                       "payload" => delivery["participant_payload"] || %{},
                       "state" => "active",
                       "notification_filter" => %{"messages" => "all", "statuses" => "none"}
                     }
                   )

          participant
      end

    participant_id = participant["participant_id"]

    {:ok, sender} =
      ConversationServer.ensure_group_conversation_user_participant(group_id, conversation_id, %{
        "user_id" => "delivery-fixture"
      })

    [{owner, _}] =
      SystemsRuntime.Registry.lookup(
        SalixIM.ConversationRegistry,
        SalixIM.ConversationParticipantActor.key(group_id, conversation_id, participant_id)
      )

    unless Process.get({:suspended_delivery, owner}) do
      :ok = SystemsRuntime.Server.suspend(owner, :infinity)
      Process.put({:suspended_delivery, owner}, true)

      on_exit(fn ->
        if SystemsRuntime.Proc.alive?(owner), do: SystemsRuntime.Server.resume(owner, :infinity)
      end)
    end

    {:ok, message} =
      ConversationServer.append_group_conversation_message(group_id, conversation_id, %{
        "participant_id" => sender["participant_id"],
        "actor_type" => "user",
        "user_id" => "delivery-fixture",
        "content" => delivery["message_content"] || "provider receipt fixture",
        "delivery_filter" => %{"participant_ids" => [participant_id]}
      })

    delivery =
      Map.merge(delivery, %{
        "message_id" => message["message_id"],
        "message_seq" => message["seq"]
      })

    delivery_id =
      Enum.join([group_id, conversation_id, message["message_id"], participant_id], ":")

    now =
      delivery["updated_at"] || delivery["created_at"] || SystemsClock.system_time(:millisecond)

    delivery =
      delivery
      |> Map.put("delivery_id", delivery_id)
      |> Map.put("participant_id", participant_id)
      |> Map.put("updated_at", now)
      |> Map.put_new("created_at", now)

    state_key =
      delivery_key(group_id, conversation_id, delivery["message_id"], participant_id)

    assert {:ok, _} = SalixStore.S3.put(state_key, Jason.encode!(delivery), if_none_match: "*")
    {participant_id, message["message_id"]}
  end

  defp wake_delivery_and_wait!(group, conversation, participant, message, statuses) do
    {:ok, target} =
      Conversations.get_group_conversation_participant(group, conversation, participant)

    if target["actor_type"] == "agent" do
      :ok = ConversationServer.wake_participant(group, conversation, participant)
      {:ok, source} = Conversations.get_group_conversation_message(group, conversation, message)

      assert eventually(fn ->
               case SalixIM.Ports.AgentDelivery.conversation_progress(
                      target["agent_id"],
                      target["payload"]["session_id"],
                      participant
                    ) do
                 {:ok, %{"seq" => seq}} -> seq >= source["seq"]
                 _ -> false
               end
             end)
    else
      wait_provider_delivery!(group, conversation, participant, message, statuses)
    end
  end

  defp wait_provider_delivery!(
         group_id,
         conversation_id,
         participant_id,
         message_id,
         expected_statuses
       ) do
    [{owner, _}] =
      SystemsRuntime.Registry.lookup(
        SalixIM.ConversationRegistry,
        SalixIM.ConversationParticipantActor.key(group_id, conversation_id, participant_id)
      )

    if Process.delete({:suspended_delivery, owner}),
      do: SystemsRuntime.Server.resume(owner, :infinity)

    expected_statuses = List.wrap(expected_statuses)

    assert :ok =
             ConversationServer.wake_participant(group_id, conversation_id, participant_id)

    assert eventually(fn ->
             case Conversations.group_conversation_delivery_status(
                    group_id,
                    conversation_id,
                    participant_id: participant_id,
                    message_id: message_id,
                    limit: 1
                  ) do
               {:ok, %{"deliveries" => [%{"status" => status}]}} ->
                 status in expected_statuses

               _ ->
                 false
             end
           end)

    assert {:ok, %{"deliveries" => [delivery]}} =
             Conversations.group_conversation_delivery_status(
               group_id,
               conversation_id,
               participant_id: participant_id,
               message_id: message_id,
               limit: 1
             )

    assert delivery["status"] in expected_statuses
    delivery
  end

  defp sign_slack_body(body, secret, timestamp \\ SystemsClock.system_time(:second)) do
    mac =
      :crypto.mac(:hmac, :sha256, secret, "v0:#{timestamp}:#{body}")
      |> Base.encode16(case: :lower)

    [
      {"x-slack-request-timestamp", Integer.to_string(timestamp)},
      {"x-slack-signature", "v0=" <> mac}
    ]
  end

  defp sign_feishu_body(
         body,
         secret,
         timestamp \\ SystemsClock.system_time(:second),
         nonce \\ "nonce"
       ) do
    signature =
      :crypto.hash(:sha256, Integer.to_string(timestamp) <> nonce <> secret <> body)
      |> Base.encode16(case: :lower)

    [
      {"x-lark-request-timestamp", Integer.to_string(timestamp)},
      {"x-lark-request-nonce", nonce},
      {"x-lark-signature", signature}
    ]
  end

  defp platform_messages!(group_id, attempts \\ 1200)
  defp platform_messages!(_, 0), do: flunk("Platform history did not commit")

  defp platform_messages!(group_id, attempts) do
    {:ok, conversation} = SalixIM.RouterConversationInput.ensure(group_id)

    {:ok, messages} =
      Conversations.list_group_conversation_messages(group_id, conversation["conversation_id"])

    case Enum.flat_map(messages, fn message ->
           if message["platform_message"], do: [message["platform_message"]], else: []
         end) do
      [] ->
        SystemsClock.sleep(25)
        platform_messages!(group_id, attempts - 1)

      messages ->
        messages
    end
  end

  defp configure_slack_tool_retry(opts) do
    SystemsRuntime.put_env(
      :salix_im,
      :slack_tool_rate_limit_retry_budget_ms,
      Keyword.fetch!(opts, :budget_ms)
    )

    SystemsRuntime.put_env(
      :salix_im,
      :slack_tool_rate_limit_max_retries,
      Keyword.fetch!(opts, :max_retries)
    )
  end

  @doc false
  def handle_slack_api_retry_telemetry(_event, measurements, metadata, owner) do
    if metadata[:component] == "salix_im" and metadata[:operation] == "slack_api_retry" do
      SystemsRuntime.Proc.send(owner, {:slack_api_retry, measurements, metadata})
    end
  end

  defp internal_send_context(agent_id, group_id, tool_call_id) do
    %{
      agent_id: agent_id,
      group_id: group_id,
      session_id: "archive-session",
      tool_call_id: tool_call_id,
      role: "router",
      runtime_kind: :internal
    }
  end

  defp seed_agent_vfs(agent_id, files) do
    events =
      Enum.map(files, fn {path, body} ->
        {:ok, event} = SalixAgent.AgentWorkspace.prepare_write(agent_id, path, body)
        event
      end)

    if events != [] do
      assert {:ok, _} =
               SalixAgent.AgentWorkspace.seed_operation(
                 agent_id,
                 "im-provider-test-seed:" <>
                   Integer.to_string(SystemsRuntime.Proc.unique_integer([:positive])),
                 %{},
                 events
               )
    end

    :ok
  end

  defp host_file!(body) do
    path =
      Path.join(
        System.tmp_dir!(),
        "salix-host-file-#{SystemsRuntime.Proc.unique_integer([:positive])}"
      )

    File.write!(path, body)
    ExUnit.Callbacks.on_exit(fn -> File.rm(path) end)
    path
  end

  # Five seconds: settled conditions return on the first check, and a loaded
  # CI runner can take longer than two seconds to settle an async tool result.
  # Settles until the condition holds; it fails on clock time if it never does.
  defp eventually(fun, _retries \\ nil), do: settle_until(fun)

  defp deterministic_feishu_uuid(api, target, operation_ref) do
    digest =
      :crypto.hash(:sha256, Enum.join([api, target, operation_ref], "\0"))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 40)

    "bft_" <> digest
  end

  defp start_slack_status_runtime! do
    start_supervised!(
      {SystemsRuntime.Registry, keys: :unique, name: SalixIM.SlackRouterStatusRegistry},
      id: SalixIM.SlackRouterStatusRegistry
    )

    start_supervised!(
      {SystemsRuntime.DynamicSupervisor,
       name: SalixIM.SlackRouterStatusFleetSup, strategy: :one_for_one},
      id: SalixIM.SlackRouterStatusFleetSup
    )

    start_supervised!(
      {SystemsRuntime.TaskSupervisor, name: SalixIM.SlackRouterStatusTaskSupervisor},
      id: SalixIM.SlackRouterStatusTaskSupervisor
    )
  end

  defp assert_router_session_delivery(_tenant, group_id, agent_id, source_id, text) do
    {:ok, session_id} = SalixIM.ProviderConnects.agent_group_router_session_id(agent_id, group_id)

    assert eventually(fn ->
             case SalixAgent.TestSupport.SessionData.read(agent_id, session_id) do
               {:ok, session} ->
                 Enum.any?(session.messages, fn msg ->
                   to_string(
                     Map.get(msg, :source_message_id) || Map.get(msg, "source_message_id") || ""
                   ) ==
                     source_id and
                     msg.role == "user" and
                     String.contains?(to_string(msg.content || ""), text)
                 end)

               _ ->
                 false
             end
           end)
  end

  defp source_message_id(message) do
    to_string(Map.get(message, :source_message_id) || Map.get(message, "source_message_id") || "")
  end

  defp assert_router_source_context(group_id, agent_id, expected_fragments) do
    {:ok, session_id} = SalixIM.ProviderConnects.agent_group_router_session_id(agent_id, group_id)

    assert eventually(fn ->
             case SalixAgent.TestSupport.SessionData.read(agent_id, session_id) do
               {:ok, session} ->
                 Enum.any?(session.messages, fn message ->
                   message.role == "user" and
                     Enum.all?(expected_fragments, &String.contains?(message.content, &1))
                 end)

               _ ->
                 false
             end
           end)
  end

  defp router_source_context!(group_id, agent_id, expected_fragment, retries \\ 1200)

  defp router_source_context!(group_id, agent_id, expected_fragment, retries)
       when retries > 0 do
    {:ok, session_id} = SalixIM.ProviderConnects.agent_group_router_session_id(agent_id, group_id)

    context =
      with {:ok, session} <- SalixAgent.InternalSessionStore.read(agent_id, session_id),
           {:ok, transcript} <-
             SalixAgent.InternalSessionStore.transcript(agent_id, session, :full) do
        Enum.find_value(transcript.messages, fn message ->
          content = to_string(message.content || "")

          if message.role == "user" and String.contains?(content, expected_fragment),
            do: content
        end)
      else
        _ -> nil
      end

    if is_binary(context) do
      context
    else
      SystemsClock.sleep(25)
      router_source_context!(group_id, agent_id, expected_fragment, retries - 1)
    end
  end

  defp router_source_context!(_group_id, _agent_id, expected_fragment, 0),
    do: flunk("router source context missing #{inspect(expected_fragment)}")

  defp recipient_im_identity_from_context!(content) when is_binary(content) do
    case Regex.run(
           ~r/recipient_im_identity(?:=|:\s*)(\{[^\n]*\})/,
           content,
           capture: :all_but_first
         ) do
      [encoded] -> Jason.decode!(encoded)
      _ -> flunk("recipient_im_identity missing from source context: #{inspect(content)}")
    end
  end

  defp router_session_message!(group_id, agent_id, source_id, retries \\ 1200)

  defp router_session_message!(group_id, agent_id, source_id, retries) when retries > 0 do
    {:ok, session_id} = SalixIM.ProviderConnects.agent_group_router_session_id(agent_id, group_id)

    message =
      with {:ok, session} <- SalixAgent.InternalSessionStore.read(agent_id, session_id),
           {:ok, transcript} <-
             SalixAgent.InternalSessionStore.transcript(agent_id, session, :full) do
        Enum.find(transcript.messages, fn message ->
          to_string(Map.get(message, :source_message_id) || "") == source_id and
            message.role == "user"
        end)
      else
        _ -> nil
      end

    if message do
      message
    else
      SystemsClock.sleep(25)
      router_session_message!(group_id, agent_id, source_id, retries - 1)
    end
  end

  defp router_session_message!(_group_id, _agent_id, source_id, 0),
    do: flunk("router session message missing #{inspect(source_id)}")

  defp router_session_trusted_origin!(group_id, agent_id, source_id, retries \\ 1200)

  defp router_session_trusted_origin!(group_id, agent_id, source_id, retries)
       when retries > 0 do
    {:ok, session_id} = SalixIM.ProviderConnects.agent_group_router_session_id(agent_id, group_id)

    origin =
      with {:ok, session} <- SalixAgent.TestSupport.SessionData.read(agent_id, session_id) do
        pending_origin =
          Enum.find_value(session.input_queue || [], fn item ->
            item = Map.new(item, fn {key, value} -> {to_string(key), value} end)

            payload =
              Map.new(item["payload"] || %{}, fn {key, value} -> {to_string(key), value} end)

            if (payload["source_message_id"] || item["dedupe_key"]) == source_id and
                 (payload["role"] || "user") == "user",
               do: payload["trusted_origin"]
          end)

        pending_origin ||
          Enum.find_value(session.messages || [], fn message ->
            if to_string(
                 Map.get(message, :source_message_id) ||
                   Map.get(message, "source_message_id") || ""
               ) == source_id and
                 (Map.get(message, :role) || Map.get(message, "role")) == "user",
               do: Map.get(message, :trusted_origin) || Map.get(message, "trusted_origin")
          end)
      else
        _ -> nil
      end

    if is_map(origin) do
      origin
    else
      SystemsClock.sleep(25)
      router_session_trusted_origin!(group_id, agent_id, source_id, retries - 1)
    end
  end

  defp router_session_trusted_origin!(_group_id, _agent_id, source_id, 0),
    do: flunk("trusted Router session origin missing #{inspect(source_id)}")

  defp fake_records_with_prefix(prefix) do
    SalixStore.S3.Fake.dump()
    |> Enum.filter(fn {key, _value} -> String.starts_with?(key, prefix) end)
    |> Map.new()
  end

  defp delete_slack_triage_channel_cutover_marker!, do: delete_cutover_markers()

  defp delete_cutover_markers do
    SalixStore.Repo.query!("""
    DELETE FROM salix_cutover_markers
    WHERE name IN ('slack_triage_channels_v1', 'slack_triage_channels_v1_preparing')
    """)

    on_exit(fn ->
      SalixStore.Repo.query!("""
      DELETE FROM salix_cutover_markers
      WHERE name = 'slack_triage_channels_v1_preparing'
      """)

      SalixStore.Repo.query!("""
      INSERT INTO salix_cutover_markers (name, completed_at, evidence)
      VALUES ('slack_triage_channels_v1', now(), '{"mode":"test-baseline"}'::jsonb)
      ON CONFLICT (name) DO NOTHING
      """)
    end)
  end

  # ---- list_connects ----

  test "Slack and Feishu app_id identity stays unique until delete",
       %{tenant: tenant, group_id: group_id} do
    assert {:ok, slack} =
             SalixIM.ProviderConnects.create_slack_im_connect(tenant, group_id, %{
               "app_id" => "A-unique",
               "client_id" => "client-1",
               "client_secret" => "secret-1",
               "signing_secret" => "sign-1"
             })

    assert {:ok, current_slack} =
             SalixIM.ProviderIdentity.find_reserved_slack_connect_by_app_id("A-unique")

    assert current_slack["connect_id"] == slack["connect_id"]

    assert {:error, {:bad_request, message}} =
             SalixIM.ProviderConnects.create_slack_im_connect(tenant, group_id, %{
               "app_id" => "A-unique",
               "client_id" => "client-2",
               "client_secret" => "secret-2",
               "signing_secret" => "sign-2"
             })

    assert message =~ "slack app_id"
    :ok = SalixIM.ProviderConnects.disable_im_connect(tenant, group_id, slack["connect_id"])

    assert {:error, {:bad_request, _}} =
             SalixIM.ProviderConnects.create_slack_im_connect(tenant, group_id, %{
               "app_id" => "A-unique",
               "client_id" => "client-3",
               "client_secret" => "secret-3",
               "signing_secret" => "sign-3"
             })

    :ok = SalixIM.ProviderConnects.delete_im_connect(tenant, group_id, slack["connect_id"])

    assert {:error, :not_found} =
             SalixIM.ProviderIdentity.find_reserved_slack_connect_by_app_id("A-unique")

    assert {:ok, _replacement} =
             SalixIM.ProviderConnects.create_slack_im_connect(tenant, group_id, %{
               "app_id" => "A-unique",
               "client_id" => "client-4",
               "client_secret" => "secret-4",
               "signing_secret" => "sign-4"
             })

    start_supervised!(MockProviderRuntime)
    base_url = BanditServer.serve!(MockProviderRuntime)
    prev = SystemsRuntime.get_env(:salix_im, :feishu_api_base_url)
    SystemsRuntime.put_env(:salix_im, :feishu_api_base_url, "#{base_url}/open-apis")
    on_exit(fn -> restore(:salix_im, :feishu_api_base_url, prev) end)

    FakeTenantAppStore.put(tenant, %{
      "app_id" => "cli_unique",
      "app_secret" => "secret-a",
      "verification_token" => "verify-a"
    })

    assert {:ok, feishu} =
             SalixIM.ProviderConnects.create_feishu_im_connect(tenant, group_id, %{
               "app_id" => "cli_unique"
             })

    assert {:error, {:bad_request, message}} =
             SalixIM.ProviderConnects.create_feishu_im_connect(tenant, group_id, %{
               "app_id" => "cli_unique"
             })

    assert message =~ "feishu app_id"
    :ok = SalixIM.ProviderConnects.disable_im_connect(tenant, group_id, feishu["connect_id"])

    assert {:error, {:bad_request, _}} =
             SalixIM.ProviderConnects.create_feishu_im_connect(tenant, group_id, %{
               "app_id" => "cli_unique"
             })

    :ok = SalixIM.ProviderConnects.delete_im_connect(tenant, group_id, feishu["connect_id"])

    assert {:ok, _replacement} =
             SalixIM.ProviderConnects.create_feishu_im_connect(tenant, group_id, %{
               "app_id" => "cli_unique"
             })
  end

  test "new Slack connect keeps Triage authority default-off without lazy mutation",
       %{tenant: tenant, group_id: group_id} do
    assert {:ok, connect} =
             SalixIM.ProviderConnects.create_slack_im_connect(tenant, group_id, %{
               "app_id" => "A-triage-default-off",
               "client_id" => "client-triage-default-off",
               "client_secret" => "secret-triage-default-off",
               "signing_secret" => "sign-triage-default-off"
             })

    assert connect["triage_enabled"] == false
    refute Map.has_key?(connect, "connect_generation")
    refute Map.has_key?(connect, "approved_channel_id")

    key = Keys.ctl_im_connect(group_id, connect["connect_id"])
    assert {:ok, stored_before} = SalixStore.CasRecord.get(key)
    assert ULID.valid?(stored_before["connect_generation"])
    assert stored_before["triage_enabled"] == false
    refute Map.has_key?(stored_before, "approved_channel_id")

    assert {:error, :slack_triage_authority_ineligible} =
             SalixIM.ProviderConnects.get_slack_triage_authority(
               tenant,
               group_id,
               connect["connect_id"]
             )

    assert SalixStore.CasRecord.get(key) == {:ok, stored_before}
  end

  test "Slack Triage channel picker returns one credential-free bounded page",
       %{tenant: tenant, group_id: group_id} do
    assert {:ok, connect} =
             SalixIM.ProviderConnects.create_slack_im_connect(tenant, group_id, %{
               "app_id" => "A-triage-picker",
               "client_id" => "client-triage-picker",
               "client_secret" => "secret-triage-picker",
               "signing_secret" => "sign-triage-picker"
             })

    assert {:ok, _completed} =
             SalixIM.ProviderConnects.complete_slack_im_connect_oauth(connect, %{
               "bot_token" => "xoxb-triage-picker",
               "bot_id" => "B-triage-picker",
               "bot_user_id" => "U-triage-picker",
               "workspace_id" => "T-triage-picker",
               "workspace_name" => "Picker Workspace",
               "enterprise_id" => nil,
               "owner_user_id" => "U-owner"
             })

    MockSlack.respond("conversations.list", %{
      "ok" => true,
      "channels" => [
        %{"id" => "C_PUBLIC", "name" => "general", "is_member" => true},
        %{
          "id" => "C_PRIVATE",
          "name" => "planning",
          "is_private" => true,
          "is_member" => true
        },
        %{"id" => "C_SHARED", "name" => "partner", "is_shared" => true},
        %{"id" => "C_ARCHIVED", "name" => "old", "is_archived" => true},
        %{"id" => "", "name" => "malformed"}
      ],
      "response_metadata" => %{"next_cursor" => "channel-page-2"}
    })

    assert {:ok,
            %{
              channels: [
                %{
                  id: "C_PUBLIC",
                  name: "general",
                  private?: false,
                  shared?: false,
                  member?: true
                },
                %{
                  id: "C_PRIVATE",
                  name: "planning",
                  private?: true,
                  shared?: false,
                  member?: true
                },
                %{
                  id: "C_SHARED",
                  name: "partner",
                  private?: false,
                  shared?: true,
                  member?: false
                }
              ],
              next_cursor: "channel-page-2"
            } = page} =
             SalixIM.ProviderConnects.list_slack_triage_channels(
               tenant,
               group_id,
               connect["connect_id"],
               "channel-page-1",
               100
             )

    request = MockSlack.last_request("conversations.list")
    assert request.auth == "Bearer xoxb-triage-picker"
    assert request.params["cursor"] == "channel-page-1"
    assert request.params["limit"] == "100"
    assert request.params["types"] == "public_channel,private_channel"
    assert request.params["exclude_archived"] == "true"

    rendered = inspect(page)
    refute rendered =~ "xoxb"
    refute rendered =~ "secret-triage-picker"

    assert {:error, :unavailable} =
             SalixIM.ProviderConnects.list_slack_triage_channels(
               SalixAgent.TestSupport.new_tenant_id(),
               group_id,
               connect["connect_id"],
               nil,
               100
             )
  end

  test "one Slack assistant owns independently fenced Triage authorities for multiple channels",
       %{tenant: tenant, group_id: group_id} do
    assert {:ok, connect} =
             SalixIM.ProviderConnects.create_slack_im_connect(tenant, group_id, %{
               "app_id" => "A-triage-multi-channel",
               "client_id" => "client-triage-multi-channel",
               "client_secret" => "secret-triage-multi-channel",
               "signing_secret" => "sign-triage-multi-channel"
             })

    assert {:ok, _completed} =
             SalixIM.ProviderConnects.complete_slack_im_connect_oauth(connect, %{
               "bot_token" => "xoxb-triage-multi-channel",
               "bot_id" => "B-triage-multi-channel",
               "bot_user_id" => "U-triage-multi-channel",
               "workspace_id" => "T-triage-multi-channel",
               "workspace_name" => "Multi-channel Workspace",
               "enterprise_id" => nil,
               "owner_user_id" => "U-owner"
             })

    key = Keys.ctl_im_connect(group_id, connect["connect_id"])
    assert {:ok, installed} = SalixStore.CasRecord.get(key)

    MockSlack.respond("conversations.info", %{
      "ok" => true,
      "channel" => %{"id" => "C-triage-alpha", "name" => "alpha"}
    })

    assert {:ok, _alpha} =
             SalixIM.ProviderConnects.provision_slack_triage_authority(
               tenant,
               group_id,
               connect["connect_id"],
               "C-triage-alpha"
             )

    assert {:ok,
            %{
              channels: [
                %{channel_id: "C-triage-alpha", channel_name: "alpha", enabled: true}
              ],
              scan_complete: true
            }} =
             SalixIM.ProviderConnects.list_configured_slack_triage_channels(
               tenant,
               group_id,
               connect["connect_id"]
             )

    assert {:ok, [legacy_posture]} = SalixIM.Triage.ReadModel.connect_posture(tenant, group_id)

    assert legacy_posture.configured_channels == [
             %{
               channel_id: "C-triage-alpha",
               channel_name: "alpha",
               enabled: true,
               expression_mode: "project"
             }
           ]

    assert :ok =
             SalixIM.ProviderConnects.set_slack_triage_enabled(
               tenant,
               group_id,
               connect["connect_id"],
               true
             )

    assert {:ok, legacy_alpha_authority} =
             SalixIM.ProviderConnects.get_slack_triage_authority(
               tenant,
               group_id,
               connect["connect_id"],
               "C-triage-alpha"
             )

    MockSlack.respond("conversations.info", %{
      "ok" => true,
      "channel" => %{"id" => "C-triage-beta", "name" => "beta"}
    })

    assert {:ok, _beta} =
             SalixIM.ProviderConnects.provision_slack_triage_authority(
               tenant,
               group_id,
               connect["connect_id"],
               "C-triage-beta"
             )

    assert :ok =
             SalixIM.ProviderConnects.verify_slack_triage_authority(legacy_alpha_authority)

    assert {:ok,
            %{
              channels: [
                %{channel_id: "C-triage-alpha", channel_name: "alpha", enabled: true},
                %{channel_id: "C-triage-beta", channel_name: "beta", enabled: true}
              ],
              scan_complete: true
            }} =
             SalixIM.ProviderConnects.list_configured_slack_triage_channels(
               tenant,
               group_id,
               connect["connect_id"]
             )

    # Adding a sibling channel must not rotate the Slack installation identity.
    assert {:ok, provisioned_connect} = SalixStore.CasRecord.get(key)
    assert provisioned_connect["connect_generation"] == installed["connect_generation"]

    assert :ok =
             SalixIM.ProviderConnects.set_slack_triage_enabled(
               tenant,
               group_id,
               connect["connect_id"],
               true
             )

    assert {:ok, alpha_authority} =
             SalixIM.ProviderConnects.get_slack_triage_authority(
               tenant,
               group_id,
               connect["connect_id"],
               "C-triage-alpha"
             )

    assert {:ok, beta_authority} =
             SalixIM.ProviderConnects.get_slack_triage_authority(
               tenant,
               group_id,
               connect["connect_id"],
               "C-triage-beta"
             )

    assert alpha_authority["approved_channel_id"] == "C-triage-alpha"
    assert beta_authority["approved_channel_id"] == "C-triage-beta"
    refute alpha_authority["connect_generation"] == beta_authority["connect_generation"]

    refs = [
      {connect["connect_id"], "C-triage-alpha"},
      {connect["connect_id"], "C-triage-beta"}
    ]

    assert {:ok, recovery_page} =
             SalixIM.ProviderConnects.resolve_slack_triage_recovery_authority_refs(refs)

    assert recovery_page.scan_complete

    assert recovery_page.authorities == %{
             {connect["connect_id"], "C-triage-alpha"} => alpha_authority,
             {connect["connect_id"], "C-triage-beta"} => beta_authority
           }

    assert :ok =
             SalixIM.ProviderConnects.set_slack_triage_channel_enabled(
               tenant,
               group_id,
               connect["connect_id"],
               "C-triage-alpha",
               false
             )

    assert {:error, :slack_triage_authority_ineligible} =
             SalixIM.ProviderConnects.get_slack_triage_authority(
               tenant,
               group_id,
               connect["connect_id"],
               "C-triage-alpha"
             )

    # Pausing alpha neither mutates nor fences beta.
    assert {:ok, ^beta_authority} =
             SalixIM.ProviderConnects.get_slack_triage_authority(
               tenant,
               group_id,
               connect["connect_id"],
               "C-triage-beta"
             )

    assert {:ok, paused_recovery_page} =
             SalixIM.ProviderConnects.resolve_slack_triage_recovery_authority_refs(refs)

    assert paused_recovery_page.authorities == %{
             {connect["connect_id"], "C-triage-beta"} => beta_authority
           }

    assert :ok =
             SalixIM.ProviderConnects.set_slack_triage_enabled(
               tenant,
               group_id,
               connect["connect_id"],
               false
             )

    assert {:error, :slack_triage_authority_ineligible} =
             SalixIM.ProviderConnects.get_slack_triage_authority(
               tenant,
               group_id,
               connect["connect_id"],
               "C-triage-beta"
             )

    assert :ok =
             SalixIM.ProviderConnects.set_slack_triage_enabled(
               tenant,
               group_id,
               connect["connect_id"],
               true
             )

    assert {:ok, reenabled_beta_authority} =
             SalixIM.ProviderConnects.get_slack_triage_authority(
               tenant,
               group_id,
               connect["connect_id"],
               "C-triage-beta"
             )

    # A global off/on cycle keeps channel configuration but fences old work.
    refute reenabled_beta_authority["connect_generation"] ==
             beta_authority["connect_generation"]
  end

  test "Slack Triage authority enable returns an exact credential-free projection",
       %{tenant: tenant, group_id: group_id, agent_id: router_agent_id} do
    assert {:ok, connect} =
             SalixIM.ProviderConnects.create_slack_im_connect(tenant, group_id, %{
               "app_id" => "A-triage-enable",
               "client_id" => "client-triage-enable",
               "client_secret" => "secret-triage-enable",
               "signing_secret" => "sign-triage-enable"
             })

    assert {:ok, _completed} =
             SalixIM.ProviderConnects.complete_slack_im_connect_oauth(connect, %{
               "bot_token" => "xoxb-triage-enable",
               "bot_id" => "B-triage-enable",
               "bot_user_id" => "U-triage-enable",
               "workspace_id" => "T-triage-enable",
               "workspace_name" => "Triage Workspace",
               "enterprise_id" => nil,
               "owner_user_id" => "U-owner"
             })

    MockSlack.respond("conversations.info", %{
      "ok" => true,
      "channel" => %{"id" => "C-triage-enable", "name" => "triage"}
    })

    assert {:ok, _provisioned} =
             SalixIM.ProviderConnects.provision_slack_triage_authority(
               tenant,
               group_id,
               connect["connect_id"],
               "C-triage-enable"
             )

    assert :ok =
             SalixIM.ProviderConnects.set_slack_triage_enabled(
               tenant,
               group_id,
               connect["connect_id"],
               true
             )

    assert {:ok, authority} =
             SalixIM.ProviderConnects.get_slack_triage_authority(
               tenant,
               group_id,
               connect["connect_id"]
             )

    assert Map.keys(authority) |> Enum.sort() ==
             Enum.sort([
               "provider",
               "triage_enabled",
               "tenant_id",
               "group_id",
               "connect_id",
               "connect_generation",
               "workspace_id",
               "approved_channel_id",
               "inbound_agent_id",
               "app_id",
               "bot_user_id",
               "bot_id",
               "oauth_completed_at"
             ])

    # The record carries the channel's display name, but the pin is written
    # against the id: a presentation label must never be able to move the
    # authority, so it is absent from the projection above.
    assert {:ok, stored} =
             SalixStore.CasRecord.get(Keys.ctl_im_connect(group_id, connect["connect_id"]))

    assert stored["approved_channel_name"] == "triage"
    refute Map.has_key?(authority, "approved_channel_name")

    assert authority["provider"] == "slack"
    assert authority["triage_enabled"] == true
    assert authority["tenant_id"] == tenant
    assert authority["group_id"] == group_id
    assert authority["connect_id"] == connect["connect_id"]
    assert ULID.valid?(authority["connect_generation"])
    assert authority["workspace_id"] == "T-triage-enable"
    assert authority["approved_channel_id"] == "C-triage-enable"
    assert authority["inbound_agent_id"] == router_agent_id
    assert authority["app_id"] == "A-triage-enable"
    assert authority["bot_user_id"] == "U-triage-enable"
    assert authority["bot_id"] == "B-triage-enable"
    assert authority["oauth_completed_at"] > 0

    encoded = Jason.encode!(authority)
    refute encoded =~ "xoxb-triage-enable"
    refute encoded =~ "secret-triage-enable"
    refute encoded =~ "sign-triage-enable"
    refute encoded =~ "oauth_state"
    refute encoded =~ "configured"
  end

  test "Slack OAuth reset rotates and revokes Triage authority while completion stays disabled",
       %{tenant: tenant, group_id: group_id} do
    assert {:ok, connect} =
             SalixIM.ProviderConnects.create_slack_im_connect(tenant, group_id, %{
               "app_id" => "A-triage-reset",
               "client_id" => "client-triage-reset",
               "client_secret" => "secret-triage-reset",
               "signing_secret" => "sign-triage-reset"
             })

    oauth = %{
      "bot_token" => "xoxb-triage-reset",
      "bot_id" => "B-triage-reset",
      "bot_user_id" => "U-triage-reset",
      "workspace_id" => "T-triage-reset",
      "workspace_name" => "Triage Workspace",
      "enterprise_id" => nil,
      "owner_user_id" => "U-owner",
      "granted_bot_scopes" => ["chat:write", "canvases:write"]
    }

    assert {:ok, _completed} =
             SalixIM.ProviderConnects.complete_slack_im_connect_oauth(connect, oauth)

    MockSlack.respond("conversations.info", %{
      "ok" => true,
      "channel" => %{"id" => "C-triage-reset", "name" => "triage"}
    })

    assert {:ok, _provisioned} =
             SalixIM.ProviderConnects.provision_slack_triage_authority(
               tenant,
               group_id,
               connect["connect_id"],
               "C-triage-reset"
             )

    assert :ok =
             SalixIM.ProviderConnects.set_slack_triage_enabled(
               tenant,
               group_id,
               connect["connect_id"],
               true
             )

    key = Keys.ctl_im_connect(group_id, connect["connect_id"])
    assert {:ok, enabled} = SalixStore.CasRecord.get(key)

    assert {:ok, reset} =
             SalixIM.ProviderConnects.update_slack_im_connect(
               tenant,
               group_id,
               connect["connect_id"],
               %{"reset_oauth" => true}
             )

    assert reset["triage_enabled"] == false
    refute Map.has_key?(reset, "approved_channel_id")

    assert {:ok, reset_stored} = SalixStore.CasRecord.get(key)
    assert ULID.valid?(reset_stored["connect_generation"])
    refute reset_stored["connect_generation"] == enabled["connect_generation"]
    assert reset_stored["triage_enabled"] == false
    refute Map.has_key?(reset_stored, "approved_channel_id")
    refute Map.has_key?(reset_stored, "bot_token")
    refute Map.has_key?(reset_stored, "workspace_id")
    refute Map.has_key?(reset_stored, "bot_id")
    refute Map.has_key?(reset_stored, "bot_user_id")
    refute Map.has_key?(reset_stored, "granted_bot_scopes")
    refute Map.has_key?(reset_stored, "granted_bot_scopes_generation")

    assert {:ok, completed_again} =
             SalixIM.ProviderConnects.complete_slack_im_connect_oauth(reset_stored, oauth)

    assert completed_again["triage_enabled"] == false
    refute Map.has_key?(completed_again, "approved_channel_id")

    assert {:ok, completed_stored} = SalixStore.CasRecord.get(key)
    # The completion rewrites authority members the reset had cleared
    # (`oauth_completed_at`, `workspace_id`, `bot_id`, `bot_user_id`), so it
    # rotates again: every connect-owned change that can retire a pinnable
    # authority is generation-fenced, which is the premise the reply-settlement
    # model reasons on.
    assert ULID.valid?(completed_stored["connect_generation"])
    refute completed_stored["connect_generation"] == reset_stored["connect_generation"]
    assert completed_stored["triage_enabled"] == false
    refute Map.has_key?(completed_stored, "approved_channel_id")

    assert {:error, :slack_triage_authority_ineligible} =
             SalixIM.ProviderConnects.get_slack_triage_authority(
               tenant,
               group_id,
               connect["connect_id"]
             )
  end

  test "Slack OAuth reset keeps the connect out of ambient legacy ingress",
       %{tenant: tenant, group_id: group_id} do
    secret = "sign-triage-reset-inert"

    assert {:ok, connect} =
             SalixIM.ProviderConnects.create_slack_im_connect(tenant, group_id, %{
               "app_id" => "A-triage-reset-inert",
               "client_id" => "client-triage-reset-inert",
               "client_secret" => "secret-triage-reset-inert",
               "signing_secret" => secret
             })

    assert {:ok, _completed} =
             SalixIM.ProviderConnects.complete_slack_im_connect_oauth(connect, %{
               "bot_token" => "xoxb-triage-reset-inert",
               "bot_id" => "B-triage-reset-inert",
               "bot_user_id" => "U-triage-reset-inert",
               "workspace_id" => "T-triage-reset-inert",
               "workspace_name" => "Reset Inert Workspace",
               "enterprise_id" => nil,
               "owner_user_id" => "U-owner"
             })

    MockSlack.respond("conversations.info", %{
      "ok" => true,
      "channel" => %{"id" => "C-triage-reset-inert", "name" => "triage"}
    })

    assert {:ok, _provisioned} =
             SalixIM.ProviderConnects.provision_slack_triage_authority(
               tenant,
               group_id,
               connect["connect_id"],
               "C-triage-reset-inert"
             )

    assert {:ok, _reset} =
             SalixIM.ProviderConnects.update_slack_im_connect(
               tenant,
               group_id,
               connect["connect_id"],
               %{"reset_oauth" => true}
             )

    key = Keys.ctl_im_connect(group_id, connect["connect_id"])
    assert {:ok, reset_stored} = SalixStore.CasRecord.get(key)
    refute Map.has_key?(reset_stored, "approved_channel_id")

    # A mention that legacy relevance would accept (and durably receipt) must
    # stay fully inert on a once-provisioned connect after OAuth reset.
    envelope =
      slack_envelope("Ev-reset-inert-mention", %{
        "type" => "app_mention",
        "user" => "U-human",
        "text" => "<@U-triage-reset-inert> hello",
        "channel" => "C-triage-reset-inert",
        "channel_type" => "channel",
        "ts" => "1787021764.000900"
      })

    raw = Jason.encode!(envelope)

    assert {:error, :ignored} =
             SalixIM.ProviderHTTP.handle_slack_event(
               reset_stored,
               envelope,
               sign_slack_body(raw, secret),
               raw
             )

    assert SalixStore.CasRecord.get(
             Keys.ctl_im_slack_event_receipt(connect["connect_id"], envelope["event_id"])
           ) == {:error, :not_found}
  end

  # Every Slack connect provisioned before the Triage slice predates
  # connect_generation, so the snapshot identity fence can never fence them.
  # Authentication therefore runs against the CANONICAL signing secret:
  # rotating the credential revokes callbacks signed with the retired one
  # immediately, for generation-less records too, with no migration.
  test "a rotated signing secret revokes a generation-less snapshot's callbacks",
       %{tenant: tenant, group_id: group_id} do
    connect_id = Ids.new_connect_id()

    stale_snapshot =
      seed_connect(group_id, connect_id, "slack", %{
        "tenant_id" => tenant,
        "app_id" => "A-generationless-rotation",
        "signing_secret" => "S1",
        "workspace_id" => "T-generationless-rotation",
        "bot_token" => "xoxb-generationless-rotation",
        "bot_user_id" => "U-generationless-bot",
        "oauth_completed_at" => 1
      })

    refute Map.has_key?(stale_snapshot, "connect_generation")
    refute Map.has_key?(stale_snapshot, "triage_enabled")

    key = Keys.ctl_im_connect(group_id, connect_id)

    assert {:ok, rotated} =
             SalixStore.CasRecord.update(key, &Map.put(&1, "signing_secret", "S2"))

    assert rotated["signing_secret"] == "S2"

    envelope =
      slack_envelope("Ev-generationless-rotation", %{
        "type" => "app_mention",
        "user" => "U-human",
        "text" => "<@U-generationless-bot> hello",
        "channel" => "C-generationless-rotation",
        "channel_type" => "channel",
        "ts" => "1787021764.000970"
      })
      |> Map.merge(%{
        "api_app_id" => "A-generationless-rotation",
        "team_id" => "T-generationless-rotation"
      })

    raw = Jason.encode!(envelope)

    # The caller still holds the pre-rotation snapshot. Verification reads the
    # stored record, so the retired credential is refused with zero effect.
    assert {:error, :invalid_signature} =
             SalixIM.ProviderHTTP.handle_slack_event(
               stale_snapshot,
               envelope,
               sign_slack_body(raw, "S1"),
               raw
             )

    assert SalixStore.CasRecord.get(
             Keys.ctl_im_slack_event_receipt(connect_id, envelope["event_id"])
           ) == {:error, :not_found}

    # The current credential is admitted through that exact same snapshot.
    assert {:ok, :accepted} =
             SalixIM.ProviderHTTP.handle_slack_event(
               stale_snapshot,
               envelope,
               sign_slack_body(raw, "S2"),
               raw
             )

    assert {:ok, _receipt} =
             SalixStore.CasRecord.get(
               Keys.ctl_im_slack_event_receipt(connect_id, envelope["event_id"])
             )
  end

  # A signing secret is not an app address. An operator who repoints a connect
  # at a NEW Slack app while keeping the secret would otherwise keep admitting
  # the retired app's callbacks with a perfectly valid signature.
  test "a callback addressed to a rotated-away Slack app is inert",
       %{tenant: tenant, group_id: group_id} do
    connect_id = Ids.new_connect_id()
    secret = "sign-app-address"

    stale_snapshot =
      seed_connect(group_id, connect_id, "slack", %{
        "tenant_id" => tenant,
        "app_id" => "A-address-old",
        "signing_secret" => secret,
        "workspace_id" => "T-address",
        "bot_token" => "xoxb-address",
        "bot_user_id" => "U-address-bot",
        "oauth_completed_at" => 1
      })

    key = Keys.ctl_im_connect(group_id, connect_id)

    assert {:ok, rotated} =
             SalixStore.CasRecord.update(key, &Map.put(&1, "app_id", "A-address-new"))

    assert rotated["signing_secret"] == secret

    envelope =
      slack_envelope("Ev-address-old-app", %{
        "type" => "app_mention",
        "user" => "U-human",
        "text" => "<@U-address-bot> hello",
        "channel" => "C-address",
        "channel_type" => "channel",
        "ts" => "1787021764.000982"
      })
      |> Map.merge(%{"api_app_id" => "A-address-old", "team_id" => "T-address"})

    raw = Jason.encode!(envelope)

    assert {:error, :ignored} =
             SalixIM.ProviderHTTP.handle_slack_event(
               stale_snapshot,
               envelope,
               sign_slack_body(raw, secret),
               raw
             )

    assert SalixStore.CasRecord.get(
             Keys.ctl_im_slack_event_receipt(connect_id, envelope["event_id"])
           ) == {:error, :not_found}

    # The same callback readdressed to the connect's current app is admitted.
    assert {:ok, current_snapshot} = SalixStore.CasRecord.get(key)
    current = Map.put(envelope, "api_app_id", "A-address-new")
    current_raw = Jason.encode!(current)

    assert {:ok, :accepted} =
             SalixIM.ProviderHTTP.handle_slack_event(
               current_snapshot,
               current,
               sign_slack_body(current_raw, secret),
               current_raw
             )
  end

  test "a stale legacy snapshot cannot wake the Router after disable",
       %{tenant: tenant, group_id: group_id, agent_id: _agent_id} do
    secret = "sign-stale-identity"

    assert {:ok, connect} =
             SalixIM.ProviderConnects.create_slack_im_connect(tenant, group_id, %{
               "app_id" => "A-stale-identity",
               "client_id" => "client-stale-identity",
               "client_secret" => "secret-stale-identity",
               "signing_secret" => secret
             })

    assert {:ok, _completed} =
             SalixIM.ProviderConnects.complete_slack_im_connect_oauth(connect, %{
               "bot_token" => "xoxb-stale-identity",
               "bot_id" => "B-stale-identity",
               "bot_user_id" => "U-stale-bot",
               "workspace_id" => "T-stale-identity",
               "workspace_name" => "Stale Identity Workspace",
               "enterprise_id" => nil,
               "owner_user_id" => "U-owner"
             })

    key = Keys.ctl_im_connect(group_id, connect["connect_id"])
    assert {:ok, active_snapshot} = SalixStore.CasRecord.get(key)

    # The callback below is authenticated against this captured snapshot.
    envelope = %{
      "type" => "event_callback",
      "api_app_id" => "A-stale-identity",
      "team_id" => "T-stale-identity",
      "event_id" => "Ev-stale-identity-mention",
      "event" => %{
        "type" => "app_mention",
        "user" => "U-human",
        "text" => "<@U-stale-bot> hello",
        "channel" => "C-stale-identity",
        "channel_type" => "channel",
        "ts" => "1787021764.000950"
      }
    }

    raw = Jason.encode!(envelope)

    # Commit a disable after the snapshot was captured. The canonical record
    # is authoritative: the queued delivery must be inert, not accepted.
    assert :ok =
             SalixIM.ProviderConnects.disable_im_connect(
               tenant,
               group_id,
               connect["connect_id"]
             )

    assert {:error, :ignored} =
             SalixIM.ProviderHTTP.handle_slack_event(
               active_snapshot,
               envelope,
               sign_slack_body(raw, secret),
               raw
             )

    assert SalixStore.CasRecord.get(
             Keys.ctl_im_slack_event_receipt(connect["connect_id"], envelope["event_id"])
           ) == {:error, :not_found}
  end

  test "Slack OAuth completion cannot replace an enabled Triage installation",
       %{tenant: tenant, group_id: group_id} do
    assert {:ok, connect} =
             SalixIM.ProviderConnects.create_slack_im_connect(tenant, group_id, %{
               "app_id" => "A-triage-completion-fence",
               "client_id" => "client-triage-completion-fence",
               "client_secret" => "secret-triage-completion-fence",
               "signing_secret" => "sign-triage-completion-fence"
             })

    assert {:ok, _completed} =
             SalixIM.ProviderConnects.complete_slack_im_connect_oauth(connect, %{
               "bot_token" => "xoxb-triage-completion-original",
               "bot_id" => "B-triage-completion-original",
               "bot_user_id" => "U-triage-completion-original",
               "workspace_id" => "T-triage-completion-original",
               "workspace_name" => "Original Workspace",
               "enterprise_id" => nil,
               "owner_user_id" => "U-owner-original"
             })

    MockSlack.respond("conversations.info", %{
      "ok" => true,
      "channel" => %{"id" => "C-triage-completion-fence", "name" => "triage"}
    })

    assert {:ok, _provisioned} =
             SalixIM.ProviderConnects.provision_slack_triage_authority(
               tenant,
               group_id,
               connect["connect_id"],
               "C-triage-completion-fence"
             )

    assert :ok =
             SalixIM.ProviderConnects.set_slack_triage_enabled(
               tenant,
               group_id,
               connect["connect_id"],
               true
             )

    key = Keys.ctl_im_connect(group_id, connect["connect_id"])
    assert {:ok, enabled} = SalixStore.CasRecord.get(key)

    assert {:error, :slack_triage_authority_conflict} =
             SalixIM.ProviderConnects.complete_slack_im_connect_oauth(enabled, %{
               "bot_token" => "xoxb-triage-completion-replacement",
               "bot_id" => "B-triage-completion-replacement",
               "bot_user_id" => "U-triage-completion-replacement",
               "workspace_id" => "T-triage-completion-replacement",
               "workspace_name" => "Replacement Workspace",
               "enterprise_id" => nil,
               "owner_user_id" => "U-owner-replacement"
             })

    assert SalixStore.CasRecord.get(key) == {:ok, enabled}
  end

  test "Slack Triage authority fails closed on Router drift until dedicated reprovision",
       %{tenant: tenant, group_id: group_id} do
    assert {:ok, connect} =
             SalixIM.ProviderConnects.create_slack_im_connect(tenant, group_id, %{
               "app_id" => "A-triage-router-drift",
               "client_id" => "client-triage-router-drift",
               "client_secret" => "secret-triage-router-drift",
               "signing_secret" => "sign-triage-router-drift"
             })

    assert {:ok, _completed} =
             SalixIM.ProviderConnects.complete_slack_im_connect_oauth(connect, %{
               "bot_token" => "xoxb-triage-router-drift",
               "bot_id" => "B-triage-router-drift",
               "bot_user_id" => "U-triage-router-drift",
               "workspace_id" => "T-triage-router-drift",
               "workspace_name" => "Triage Workspace",
               "enterprise_id" => nil,
               "owner_user_id" => "U-owner"
             })

    MockSlack.respond("conversations.info", %{
      "ok" => true,
      "channel" => %{"id" => "C-triage-router-drift", "name" => "triage"}
    })

    assert {:ok, _provisioned} =
             SalixIM.ProviderConnects.provision_slack_triage_authority(
               tenant,
               group_id,
               connect["connect_id"],
               "C-triage-router-drift"
             )

    assert :ok =
             SalixIM.ProviderConnects.set_slack_triage_enabled(
               tenant,
               group_id,
               connect["connect_id"],
               true
             )

    key = Keys.ctl_im_connect(group_id, connect["connect_id"])
    assert {:ok, enabled} = SalixStore.CasRecord.get(key)

    {:ok, next_router} =
      create_control_agent(
        %{"name" => "Next Router", "group_id" => group_id, "role" => "router"},
        tenant
      )

    assert {:ok, _group} =
             SalixStore.CasRecord.update(Keys.ctl_group(group_id), fn group ->
               Map.put(group, "router_agent_id", next_router["agent_id"])
             end)

    assert {:error, :slack_triage_authority_ineligible} =
             SalixIM.ProviderConnects.get_slack_triage_authority(
               tenant,
               group_id,
               connect["connect_id"]
             )

    assert SalixStore.CasRecord.get(key) == {:ok, enabled}

    assert {:ok, reprovisioned} =
             SalixIM.ProviderConnects.provision_slack_triage_authority(
               tenant,
               group_id,
               connect["connect_id"],
               "C-triage-router-drift"
             )

    assert reprovisioned["inbound_agent_id"] == next_router["agent_id"]
    assert reprovisioned["triage_enabled"] == false

    assert {:ok, reprovisioned_stored} = SalixStore.CasRecord.get(key)
    assert reprovisioned_stored["inbound_agent_id"] == next_router["agent_id"]
    assert reprovisioned_stored["triage_enabled"] == false
    assert reprovisioned_stored["connect_generation"] == enabled["connect_generation"]

    refute reprovisioned_stored["triage_activation_generation"] ==
             enabled["triage_activation_generation"]
  end

  test "generic Slack update fences Triage identity drift and cannot write authority attrs",
       %{tenant: tenant, group_id: group_id} do
    assert {:ok, connect} =
             SalixIM.ProviderConnects.create_slack_im_connect(tenant, group_id, %{
               "app_id" => "A-triage-generic-update",
               "client_id" => "client-triage-generic-update",
               "client_secret" => "secret-triage-generic-update",
               "signing_secret" => "sign-triage-generic-update"
             })

    assert {:ok, _completed} =
             SalixIM.ProviderConnects.complete_slack_im_connect_oauth(connect, %{
               "bot_token" => "xoxb-triage-generic-update",
               "bot_id" => "B-triage-generic-update",
               "bot_user_id" => "U-triage-generic-update",
               "workspace_id" => "T-triage-generic-update",
               "workspace_name" => "Triage Workspace",
               "enterprise_id" => nil,
               "owner_user_id" => "U-owner"
             })

    MockSlack.respond("conversations.info", %{
      "ok" => true,
      "channel" => %{"id" => "C-triage-generic-update", "name" => "triage"}
    })

    assert {:ok, _provisioned} =
             SalixIM.ProviderConnects.provision_slack_triage_authority(
               tenant,
               group_id,
               connect["connect_id"],
               "C-triage-generic-update"
             )

    assert :ok =
             SalixIM.ProviderConnects.set_slack_triage_enabled(
               tenant,
               group_id,
               connect["connect_id"],
               true
             )

    key = Keys.ctl_im_connect(group_id, connect["connect_id"])
    assert {:ok, enabled} = SalixStore.CasRecord.get(key)

    {:ok, worker} =
      create_control_agent(
        %{"name" => "Worker", "group_id" => group_id, "role" => "worker"},
        tenant
      )

    assert {:ok, updated} =
             SalixIM.ProviderConnects.update_slack_im_connect(
               tenant,
               group_id,
               connect["connect_id"],
               %{
                 "client_secret" => "secret-triage-generic-update-next",
                 "inbound_agent_id" => worker["agent_id"],
                 "triage_enabled" => true,
                 "connect_generation" => "forged-generation",
                 "approved_channel_id" => "C-forged"
               }
             )

    assert updated["triage_enabled"] == false
    assert updated["approved_channel_id"] == "C-triage-generic-update"
    assert updated["inbound_agent_id"] == worker["agent_id"]

    assert {:ok, updated_stored} = SalixStore.CasRecord.get(key)
    assert ULID.valid?(updated_stored["connect_generation"])
    refute updated_stored["connect_generation"] == enabled["connect_generation"]
    refute updated_stored["connect_generation"] == "forged-generation"
    assert updated_stored["triage_enabled"] == false
    assert updated_stored["approved_channel_id"] == "C-triage-generic-update"
    assert updated_stored["client_secret"] == "secret-triage-generic-update-next"

    assert {:error, :slack_triage_authority_ineligible} =
             SalixIM.ProviderConnects.get_slack_triage_authority(
               tenant,
               group_id,
               connect["connect_id"]
             )
  end

  test "ordinary Slack disable revokes Triage and ordinary enable cannot restore it",
       %{tenant: tenant, group_id: group_id} do
    assert {:ok, connect} =
             SalixIM.ProviderConnects.create_slack_im_connect(tenant, group_id, %{
               "app_id" => "A-triage-disable",
               "client_id" => "client-triage-disable",
               "client_secret" => "secret-triage-disable",
               "signing_secret" => "sign-triage-disable"
             })

    assert {:ok, _completed} =
             SalixIM.ProviderConnects.complete_slack_im_connect_oauth(connect, %{
               "bot_token" => "xoxb-triage-disable",
               "bot_id" => "B-triage-disable",
               "bot_user_id" => "U-triage-disable",
               "workspace_id" => "T-triage-disable",
               "workspace_name" => "Triage Workspace",
               "enterprise_id" => nil,
               "owner_user_id" => "U-owner"
             })

    MockSlack.respond("conversations.info", %{
      "ok" => true,
      "channel" => %{"id" => "C-triage-disable", "name" => "triage"}
    })

    assert {:ok, _provisioned} =
             SalixIM.ProviderConnects.provision_slack_triage_authority(
               tenant,
               group_id,
               connect["connect_id"],
               "C-triage-disable"
             )

    assert :ok =
             SalixIM.ProviderConnects.set_slack_triage_enabled(
               tenant,
               group_id,
               connect["connect_id"],
               true
             )

    key = Keys.ctl_im_connect(group_id, connect["connect_id"])
    assert {:ok, enabled} = SalixStore.CasRecord.get(key)

    assert {:ok, enabled_authority} =
             SalixIM.ProviderConnects.get_slack_triage_authority(
               tenant,
               group_id,
               connect["connect_id"],
               "C-triage-disable"
             )

    assert :ok =
             SalixIM.ProviderConnects.disable_im_connect(
               tenant,
               group_id,
               connect["connect_id"]
             )

    assert {:ok, disabled} = SalixStore.CasRecord.get(key)
    assert disabled["triage_enabled"] == false
    # Revoking the global Triage switch rotates the activation fence while the
    # Slack installation identity remains stable for every configured channel.
    assert ULID.valid?(disabled["connect_generation"])
    assert disabled["connect_generation"] == enabled["connect_generation"]

    refute disabled["triage_activation_generation"] ==
             enabled["triage_activation_generation"]

    assert {:error, :slack_triage_authority_stale} =
             SalixIM.ProviderConnects.verify_slack_triage_authority(enabled_authority)

    assert :ok =
             SalixIM.ProviderConnects.enable_im_connect(
               tenant,
               group_id,
               connect["connect_id"]
             )

    assert {:error, :slack_triage_authority_ineligible} =
             SalixIM.ProviderConnects.get_slack_triage_authority(
               tenant,
               group_id,
               connect["connect_id"]
             )

    assert :ok =
             SalixIM.ProviderConnects.set_slack_triage_enabled(
               tenant,
               group_id,
               connect["connect_id"],
               true
             )

    assert :ok =
             SalixIM.ProviderConnects.delete_im_connect(
               tenant,
               group_id,
               connect["connect_id"]
             )

    assert {:error, :slack_triage_authority_ineligible} =
             SalixIM.ProviderConnects.get_slack_triage_authority(
               tenant,
               group_id,
               connect["connect_id"]
             )

    assert {:error, :slack_triage_authority_ineligible} =
             SalixIM.ProviderConnects.set_slack_triage_enabled(
               tenant,
               group_id,
               connect["connect_id"],
               false
             )
  end

  test "Slack Triage enable racing OAuth reset cannot revive stale authority",
       %{tenant: tenant, group_id: group_id} do
    on_exit(fn ->
      if SalixStore.S3.Fake.paused?(), do: SalixStore.S3.Fake.release_pause()
    end)

    assert {:ok, connect} =
             SalixIM.ProviderConnects.create_slack_im_connect(tenant, group_id, %{
               "app_id" => "A-triage-enable-reset-race",
               "client_id" => "client-triage-enable-reset-race",
               "client_secret" => "secret-triage-enable-reset-race",
               "signing_secret" => "sign-triage-enable-reset-race"
             })

    assert {:ok, _completed} =
             SalixIM.ProviderConnects.complete_slack_im_connect_oauth(connect, %{
               "bot_token" => "xoxb-triage-enable-reset-race",
               "bot_id" => "B-triage-enable-reset-race",
               "bot_user_id" => "U-triage-enable-reset-race",
               "workspace_id" => "T-triage-enable-reset-race",
               "workspace_name" => "Triage Workspace",
               "enterprise_id" => nil,
               "owner_user_id" => "U-owner"
             })

    MockSlack.respond("conversations.info", %{
      "ok" => true,
      "channel" => %{"id" => "C-triage-enable-reset-race", "name" => "triage"}
    })

    assert {:ok, _provisioned} =
             SalixIM.ProviderConnects.provision_slack_triage_authority(
               tenant,
               group_id,
               connect["connect_id"],
               "C-triage-enable-reset-race"
             )

    key = Keys.ctl_im_connect(group_id, connect["connect_id"])
    assert {:ok, before_race} = SalixStore.CasRecord.get(key)

    :ok = SalixStore.S3.Fake.set_fault({:pause, :put, key})

    enable_task =
      SystemsRuntime.Task.async(fn ->
        SalixIM.ProviderConnects.set_slack_triage_enabled(
          tenant,
          group_id,
          connect["connect_id"],
          true
        )
      end)

    assert eventually(fn -> SalixStore.S3.Fake.paused?() end, 1200)

    # The reset is a later write than the enable's read.
    SystemsClock.sleep(1)

    assert {:ok, reset} =
             SalixIM.ProviderConnects.update_slack_im_connect(
               tenant,
               group_id,
               connect["connect_id"],
               %{"reset_oauth" => true}
             )

    assert reset["triage_enabled"] == false
    :ok = SalixStore.S3.Fake.release_pause()

    assert settled_await(enable_task) == {:error, :slack_triage_authority_conflict}

    assert {:ok, after_race} = SalixStore.CasRecord.get(key)
    assert after_race["triage_enabled"] == false
    refute after_race["connect_generation"] == before_race["connect_generation"]
    refute Map.has_key?(after_race, "approved_channel_id")
    refute Map.has_key?(after_race, "bot_token")
    refute Map.has_key?(after_race, "workspace_id")

    assert {:error, :slack_triage_authority_ineligible} =
             SalixIM.ProviderConnects.get_slack_triage_authority(
               tenant,
               group_id,
               connect["connect_id"]
             )
  end

  # Deletion retires the authority without touching any authority member, so an
  # unfenced tombstone left the generation intact while readiness (which demands
  # `deleted_at == nil`) went false — a captured pin that fails its final re-read
  # with no epoch to explain it, a state the reply-settlement model has no room
  # for. Delete rotates in the same CAS so it lands as a plain epoch bump.
  test "Slack connect delete rotates the Triage generation and retires captured pins",
       %{tenant: tenant, group_id: group_id} do
    assert {:ok, connect} =
             SalixIM.ProviderConnects.create_slack_im_connect(tenant, group_id, %{
               "app_id" => "A-triage-delete-fence",
               "client_id" => "client-triage-delete-fence",
               "client_secret" => "secret-triage-delete-fence",
               "signing_secret" => "sign-triage-delete-fence"
             })

    assert {:ok, _completed} =
             SalixIM.ProviderConnects.complete_slack_im_connect_oauth(connect, %{
               "bot_token" => "xoxb-triage-delete-fence",
               "bot_id" => "B-triage-delete-fence",
               "bot_user_id" => "U-triage-delete-fence",
               "workspace_id" => "T-triage-delete-fence",
               "workspace_name" => "Triage Workspace",
               "enterprise_id" => nil,
               "owner_user_id" => "U-owner"
             })

    MockSlack.respond("conversations.info", %{
      "ok" => true,
      "channel" => %{"id" => "C-triage-delete-fence", "name" => "triage"}
    })

    assert {:ok, _provisioned} =
             SalixIM.ProviderConnects.provision_slack_triage_authority(
               tenant,
               group_id,
               connect["connect_id"],
               "C-triage-delete-fence"
             )

    assert :ok =
             SalixIM.ProviderConnects.set_slack_triage_enabled(
               tenant,
               group_id,
               connect["connect_id"],
               true
             )

    assert {:ok, authority} =
             SalixIM.ProviderConnects.get_slack_triage_authority(
               tenant,
               group_id,
               connect["connect_id"]
             )

    assert :ok = SalixIM.ProviderConnects.verify_slack_triage_authority(authority)

    # The snapshot a redelivered callback carries, captured while the connect
    # was still live. The public entry re-reads the canonical record from it,
    # so it must be the PRE-delete one for the aftermath assertion to mean
    # anything.
    assert {:ok, live_snapshot} =
             SalixIM.ProviderConnects.get_active_connect_by_id(
               group_id,
               connect["connect_id"],
               "slack"
             )

    assert :ok =
             SalixIM.ProviderConnects.delete_im_connect(
               tenant,
               group_id,
               connect["connect_id"]
             )

    assert {:ok, deleted} =
             SalixStore.CasRecord.get(Keys.ctl_im_connect(group_id, connect["connect_id"]))

    refute is_nil(deleted["deleted_at"])
    assert ULID.valid?(deleted["connect_generation"])
    refute deleted["connect_generation"] == authority["connect_generation"]

    # The in-flight attempt's final pin re-read fails exactly like every other
    # fenced drift.
    assert {:error, :slack_triage_authority_stale} =
             SalixIM.ProviderConnects.verify_slack_triage_authority(authority)

    assert {:error, :slack_triage_authority_ineligible} =
             SalixIM.ProviderConnects.get_slack_triage_authority(
               tenant,
               group_id,
               connect["connect_id"]
             )

    # The PUBLIC-entry aftermath, asserted rather than asserted-about: the
    # redelivered thread reply is `{:error, :not_found}` at the ingress
    # re-read (`current_slack_ingress_connect/1`, which the web router
    # surfaces as HTTP 404). A deleted connect is NOT an outer-gate 2xx
    # settlement — nothing routes, and no reply matrix is consulted.
    redelivery = %{
      "type" => "event_callback",
      "api_app_id" => "A-triage-delete-fence",
      "team_id" => "T-triage-delete-fence",
      "event_id" => "Ev-triage-delete-fence-redelivery",
      "event" => %{
        "type" => "message",
        "user" => "U-human",
        "text" => "still talking in the thread",
        "channel" => "C-triage-delete-fence",
        "channel_type" => "channel",
        "ts" => "91.200",
        "thread_ts" => "91.100"
      }
    }

    raw = Jason.encode!(redelivery)

    assert {:error, :not_found} =
             SalixIM.ProviderHTTP.handle_slack_event(
               live_snapshot,
               redelivery,
               sign_slack_body(raw, "sign-triage-delete-fence"),
               raw
             )
  end

  # A record the scan read as bare can be DELETED before the backfill's CAS
  # lands. The re-check inside the CAS refuses to establish, and that refusal
  # has to be a true no-op: no same-body PUT over the tombstone the deleter just
  # wrote, and a summary that buckets the record as skipped_deleted — not as
  # established off the generation `delete_im_connect/3` put on the tombstone.
  test "a delete racing the generation backfill skips the record and writes nothing",
       %{tenant: tenant, group_id: group_id} do
    on_exit(fn ->
      if SalixStore.S3.Fake.paused?(), do: SalixStore.S3.Fake.release_pause()
    end)

    connect_id = Ids.new_connect_id()

    bare =
      seed_connect(group_id, connect_id, "slack", %{
        "tenant_id" => tenant,
        "app_id" => "A-bf-delete-race",
        "workspace_id" => "T-bf-delete-race",
        "bot_token" => "xoxb-bf-delete-race",
        "oauth_completed_at" => 1
      })

    refute Map.has_key?(bare, "connect_generation")

    key = Keys.ctl_im_connect(group_id, connect_id)

    # Park the backfill's establishing PUT so the delete lands strictly between
    # the scan's read and the CAS commit.
    :ok = SalixStore.S3.Fake.set_fault({:pause, :put, key})

    backfill_task =
      SystemsRuntime.Task.async(fn ->
        SalixIM.ProviderConnects.backfill_slack_connect_generations(dry_run: false)
      end)

    assert eventually(fn -> SalixStore.S3.Fake.paused?() end, 1200)

    assert :ok = SalixIM.ProviderConnects.delete_im_connect(tenant, group_id, connect_id)

    assert {:ok, tombstone} = SalixStore.CasRecord.get(key)
    refute is_nil(tombstone["deleted_at"])
    assert ULID.valid?(tombstone["connect_generation"])

    # From here on the log holds only writes issued AFTER the delete: the parked
    # PUT was logged when it was first attempted, and releasing it replays
    # through `apply_put/5` without logging again.
    :ok = SalixStore.S3.Fake.reset_put_log()
    :ok = SalixStore.S3.Fake.release_pause()

    assert {:ok, summary} = settled_await(backfill_task)

    assert summary == %{
             dry_run: false,
             scanned: 1,
             slack: 1,
             already_generation: 0,
             skipped_deleted: 1,
             established: 0,
             errors: []
           }

    # No write at all after the delete. Content equality alone would NOT catch
    # this: the released PUT fails its precondition, the CAS retries, and a
    # closure returning `rec` instead of the `{:unchanged, rec}` abort would
    # commit a same-body rewrite of the tombstone that is byte-identical.
    refute key in SalixStore.S3.Fake.put_log()
    assert SalixStore.CasRecord.get(key) == {:ok, tombstone}
  end

  describe "backfill_slack_connect_generations/1" do
    setup %{tenant: tenant, group_id: group_id} do
      bare_one =
        seed_connect(group_id, "bf-bare-one", "slack", %{
          "tenant_id" => tenant,
          "app_id" => "A-bf-bare-one",
          "workspace_id" => "T-bf-bare-one",
          "bot_token" => "xoxb-bf-bare-one",
          "oauth_completed_at" => 1
        })

      bare_two =
        seed_connect(group_id, "bf-bare-two", "slack", %{
          "tenant_id" => tenant,
          "app_id" => "A-bf-bare-two",
          "workspace_id" => "T-bf-bare-two",
          "bot_token" => "xoxb-bf-bare-two",
          "oauth_completed_at" => 1
        })

      generational =
        seed_connect(group_id, "bf-generational", "slack", %{
          "tenant_id" => tenant,
          "app_id" => "A-bf-generational",
          "workspace_id" => "T-bf-generational",
          "bot_token" => "xoxb-bf-generational",
          "connect_generation" => ULID.generate(),
          "oauth_completed_at" => 1
        })

      deleted =
        seed_connect(group_id, "bf-deleted", "slack", %{
          "tenant_id" => tenant,
          "app_id" => "A-bf-deleted",
          "workspace_id" => "T-bf-deleted",
          "bot_token" => "xoxb-bf-deleted",
          "oauth_completed_at" => 1,
          "deleted_at" => SystemsClock.system_time(:millisecond)
        })

      feishu =
        seed_connect(group_id, "bf-feishu", "feishu", %{
          "tenant_id" => tenant,
          "app_id" => "cli-bf-feishu",
          "app_secret" => "fs-bf-feishu"
        })

      {:ok,
       seeded: %{
         "bf-bare-one" => bare_one,
         "bf-bare-two" => bare_two,
         "bf-generational" => generational,
         "bf-deleted" => deleted,
         "bf-feishu" => feishu
       }}
    end

    test "defaults to a dry run that reports the work without writing", %{
      group_id: group_id,
      seeded: seeded
    } do
      assert {:ok, summary} = SalixIM.ProviderConnects.backfill_slack_connect_generations()

      assert summary == %{
               dry_run: true,
               scanned: 5,
               slack: 4,
               already_generation: 1,
               skipped_deleted: 1,
               established: 2,
               errors: []
             }

      Enum.each(seeded, fn {connect_id, rec} ->
        assert SalixStore.CasRecord.get(Keys.ctl_im_connect(group_id, connect_id)) == {:ok, rec}
      end)
    end

    test "a real run establishes exactly the generation-less active Slack connects and is idempotent",
         %{group_id: group_id, seeded: seeded} do
      assert {:ok, summary} =
               SalixIM.ProviderConnects.backfill_slack_connect_generations(dry_run: false)

      assert summary == %{
               dry_run: false,
               scanned: 5,
               slack: 4,
               already_generation: 1,
               skipped_deleted: 1,
               established: 2,
               errors: []
             }

      assert {:ok, bare_one} =
               SalixStore.CasRecord.get(Keys.ctl_im_connect(group_id, "bf-bare-one"))

      assert {:ok, bare_two} =
               SalixStore.CasRecord.get(Keys.ctl_im_connect(group_id, "bf-bare-two"))

      assert ULID.valid?(bare_one["connect_generation"])
      assert ULID.valid?(bare_two["connect_generation"])
      refute bare_one["connect_generation"] == bare_two["connect_generation"]

      assert Map.drop(bare_one, ["connect_generation", "updated_at"]) ==
               Map.drop(seeded["bf-bare-one"], ["connect_generation", "updated_at"])

      # Untouched: a record that already carried an epoch, a tombstone whose
      # epoch is retired, and every non-Slack provider.
      Enum.each(["bf-generational", "bf-deleted", "bf-feishu"], fn connect_id ->
        assert SalixStore.CasRecord.get(Keys.ctl_im_connect(group_id, connect_id)) ==
                 {:ok, seeded[connect_id]}
      end)

      assert {:ok, second} =
               SalixIM.ProviderConnects.backfill_slack_connect_generations(dry_run: false)

      assert second == %{
               dry_run: false,
               scanned: 5,
               slack: 4,
               already_generation: 3,
               skipped_deleted: 1,
               established: 0,
               errors: []
             }

      assert SalixStore.CasRecord.get(Keys.ctl_im_connect(group_id, "bf-bare-one")) ==
               {:ok, bare_one}

      assert SalixStore.CasRecord.get(Keys.ctl_im_connect(group_id, "bf-bare-two")) ==
               {:ok, bare_two}
    end

    test "a backfilled generation does not disturb a live captured authority", %{
      tenant: tenant,
      group_id: group_id,
      agent_id: router_agent_id
    } do
      delete_slack_triage_channel_cutover_marker!()

      seed_raw_connect(group_id, "bf-live-authority", "slack", %{
        "tenant_id" => tenant,
        "app_id" => "A-bf-live",
        "workspace_id" => "T-bf-live",
        "bot_token" => "xoxb-bf-live",
        "bot_id" => "B-bf-live",
        "bot_user_id" => "U-bf-live",
        "approved_channel_id" => "C-bf-live",
        "inbound_agent_id" => router_agent_id,
        "connect_generation" => ULID.generate(),
        "triage_enabled" => true,
        "oauth_completed_at" => 1
      })

      assert {:ok, authority} =
               SalixIM.ProviderConnects.get_slack_triage_authority(
                 tenant,
                 group_id,
                 "bf-live-authority"
               )

      assert {:ok, _summary} =
               SalixIM.ProviderConnects.backfill_slack_connect_generations(dry_run: false)

      assert :ok = SalixIM.ProviderConnects.verify_slack_triage_authority(authority)
    end

    test "rejects a non-boolean dry_run option" do
      assert {:error, :invalid_slack_generation_backfill_options} =
               SalixIM.ProviderConnects.backfill_slack_connect_generations(dry_run: "yes")
    end
  end

  describe "list_connects/1" do
    test "external connects come from im_connects and hide incomplete/disabled rows",
         %{tenant: tenant, group_id: group_id, agent_id: agent_id} do
      slack_generation = ULID.generate()

      seed_connect(group_id, "sl1", "slack", %{
        "tenant_id" => tenant,
        "workspace_id" => "T1",
        "workspace_name" => "Acme",
        "enterprise_id" => "E9",
        "bot_token" => "xoxb-test",
        "granted_bot_scopes" => ["chat:write", "canvases:write"],
        "granted_bot_scopes_generation" => slack_generation,
        "connect_generation" => slack_generation,
        "oauth_completed_at" => 1
      })

      seed_connect(group_id, "sl2", "slack", %{
        "tenant_id" => tenant,
        "workspace_id" => "T2",
        "bot_token" => "xoxb-test",
        "oauth_completed_at" => 1
      })

      seed_connect(group_id, "tg1", "telegram", %{
        "tenant_id" => tenant,
        "bot_token" => "tg-token",
        "status" => "connected",
        "bot_user_id" => "1001",
        "bot_username" => "bridge_bot"
      })

      seed_connect(group_id, "wx1", "wechat", %{
        "tenant_id" => tenant,
        "status" => "connected",
        "wechat_id" => "wx-1",
        "base_url" => "https://wechat.example",
        "token" => "wx-secret",
        "latest_context_token" => "ctx-secret"
      })

      seed_connect(group_id, "fs1", "feishu", %{
        "tenant_id" => tenant,
        "status" => "connected",
        "app_id" => "cli_secret",
        "app_name" => "Bridge",
        "app_secret" => "fs-secret",
        "verification_token" => "verify-secret",
        "encrypt_key" => "encrypt-secret",
        "tenant_key" => "tenant-a"
      })

      # Hidden: incomplete OAuth, disabled, deleted, blank workspace id.
      seed_connect(group_id, "sl3", "slack", %{
        "tenant_id" => tenant,
        "workspace_id" => "T3",
        "workspace_name" => "Half",
        "bot_token" => "xoxb-test",
        "oauth_completed_at" => 0
      })

      seed_connect(group_id, "sl4", "slack", %{
        "tenant_id" => tenant,
        "workspace_id" => "T4",
        "bot_token" => "xoxb-test",
        "oauth_completed_at" => 1,
        "disabled_at" => 123
      })

      seed_connect(group_id, "sl5", "slack", %{
        "tenant_id" => tenant,
        "workspace_id" => "T5",
        "bot_token" => "xoxb-test",
        "oauth_completed_at" => 1,
        "deleted_at" => 456
      })

      seed_connect(group_id, "sl-blank", "slack", %{
        "tenant_id" => tenant,
        "workspace_id" => "",
        "bot_token" => "xoxb-test",
        "oauth_completed_at" => 1
      })

      seed_connect(group_id, "tg-pending", "telegram", %{
        "tenant_id" => tenant,
        "status" => "configured",
        "bot_token" => "tg-token"
      })

      seed_connect(group_id, "wx-pending", "wechat", %{
        "tenant_id" => tenant,
        "status" => "pending",
        "wechat_id" => "wx-pending"
      })

      seed_connect(group_id, "fs-error", "feishu", %{
        "tenant_id" => tenant,
        "status" => "error",
        "app_id" => "cli_error",
        "app_name" => "Broken"
      })

      assert {:ok, connects} = Provider.list_connects(agent_id)
      slack = Enum.filter(connects, &(&1["provider"] == "slack"))

      assert slack == [
               %{
                 "connect_id" => "sl1",
                 "provider" => "slack",
                 "workspace_id" => "T1",
                 "workspace_name" => "Acme",
                 "enterprise_id" => "E9",
                 "oauth_bot_scopes" => %{
                   "status" => "known",
                   "scopes" => ["canvases:write", "chat:write"],
                   "observed_at" => 1
                 }
               },
               %{
                 "connect_id" => "sl2",
                 "provider" => "slack",
                 "workspace_id" => "T2",
                 "workspace_name" => "",
                 "oauth_bot_scopes" => %{"status" => "unknown"}
               }
             ]

      assert Enum.find(connects, &(&1["connect_id"] == "tg1")) == %{
               "connect_id" => "tg1",
               "provider" => "telegram",
               "bot_user_id" => "1001",
               "bot_username" => "bridge_bot"
             }

      assert Enum.filter(connects, &(&1["provider"] == "wechat")) == [
               %{"connect_id" => "wx1", "provider" => "wechat", "wechat_id" => "wx-1"}
             ]

      assert Enum.find(connects, &(&1["connect_id"] == "fs1")) == %{
               "connect_id" => "fs1",
               "provider" => "feishu",
               "app_name" => "Bridge",
               "tenant_key" => "tenant-a"
             }

      refute Enum.any?(connects, &(&1["connect_id"] in ["tg-pending", "wx-pending", "fs-error"]))

      forbidden =
        ~w(app_id app_secret verification_token encrypt_key bot_token token latest_context_token api_base_url file_base_url tool_name api apis params)

      for connect <- connects, key <- forbidden do
        refute Map.has_key?(connect, key), "#{connect["connect_id"]} leaked #{key}"
      end
    end
  end

  # ---- provider manuals ----

  describe "provider_manual/1" do
  end

  # ---- slack delivery ----

  describe "call_api/4 slack" do
    setup %{tenant: tenant, group_id: group_id} do
      seed_connect(group_id, "sl1", "slack", %{
        "tenant_id" => tenant,
        "app_id" => "A1",
        "signing_secret" => "task-card-signing-secret",
        "workspace_id" => "T1",
        "workspace_name" => "Acme",
        "bot_user_id" => "Ubot",
        "bot_token" => "xoxb-test",
        "oauth_completed_at" => 1
      })

      %{slack_connect_id: "sl1"}
    end

    test "Router Slack replies can target another thread or channel regardless of activation source",
         %{
           agent_id: agent_id,
           slack_connect_id: connect_id
         } do
      source_message_id = "im_provider:slack:#{connect_id}:event-source-thread"

      trusted_origin = %{
        "provider" => "slack",
        "source_actor_type" => "provider_user",
        "source_message_id" => source_message_id,
        "provider_context" => %{
          "connect_id" => connect_id,
          "channel_id" => "C-thread-race",
          "thread_ts" => "1788502784.380329",
          "message_ts" => "1788502784.380329"
        }
      }

      prior_source_message_id = "im_provider:slack:#{connect_id}:event-prior-thread"

      prior_origin =
        trusted_origin
        |> put_in(["source_message_id"], prior_source_message_id)
        |> put_in(["provider_context", "thread_ts"], "1788502784.112249")
        |> put_in(["provider_context", "message_ts"], "1788502784.112249")

      metadata = %{
        "tool_context" => %{
          "source_message_id" => source_message_id,
          "source_message_ids" => [prior_source_message_id, source_message_id],
          "trusted_origin" => trusted_origin,
          "trusted_origins" => [prior_origin, trusted_origin]
        }
      }

      for {channel, thread_ts, context} <- [
            {"C-thread-race", "1788502784.112249", metadata},
            {"C-other", "1788502784.380329", metadata},
            {"C-thread-race", "1788502784.380329",
             put_in(metadata, ["tool_context", "source_message_id"], "internal-current-source")},
            {"C-thread-race", "1788502784.380329", metadata}
          ] do
        MockSlack.respond("chat.postMessage", %{
          "ok" => true,
          "channel" => channel,
          "ts" => "1788502785.000001"
        })

        before_count = length(MockSlack.requests("chat.postMessage"))

        assert {:ok, %{"channel" => ^channel}} =
                 call(
                   agent_id,
                   "slack",
                   "slack.post_message",
                   connect_id,
                   %{"channel" => channel, "thread_ts" => thread_ts, "text" => "Router reply"},
                   context
                 )

        requests = MockSlack.requests("chat.postMessage")
        assert length(requests) == before_count + 1

        request = List.last(requests)
        assert request.params["channel"] == channel
        assert request.params["thread_ts"] == thread_ts
      end

      # Removing the activation fence does not make unknown connects accessible.
      before_count = length(MockSlack.requests("chat.postMessage"))

      assert {:error, "connect not found"} =
               call(
                 agent_id,
                 "slack",
                 "slack.post_message",
                 "sl-other",
                 %{"channel" => "C-other", "thread_ts" => "1.0", "text" => "Router reply"},
                 metadata
               )

      assert length(MockSlack.requests("chat.postMessage")) == before_count
    end

    test "Router explicitly hands a Slack thread to an existing Task", %{
      tenant: tenant,
      group_id: group_id,
      agent_id: router_id,
      slack_connect_id: connect_id
    } do
      previous_delivery = SystemsRuntime.get_env(:salix_im, :agent_delivery_mod)
      SystemsRuntime.put_env(:salix_im, :agent_delivery_mod, FakeAgentDelivery)
      SystemsRuntime.put_env(:salix_im, :fake_agent_delivery_test_pid, SystemsRuntime.Proc.self())

      on_exit(fn ->
        restore(:salix_im, :agent_delivery_mod, previous_delivery)
        SystemsRuntime.delete_env(:salix_im, :fake_agent_delivery_test_pid)
      end)

      {conversation_id, worker_id} =
        create_slack_task!(tenant, group_id, router_id, "Own the Slack handover")

      settle_receive({:agent_delivery, ^worker_id, _initial_task_payload, _initial_task_opts})

      put_conversation_links_config(
        tenant,
        "https://teams.example.test/tasks/{tenant_id}/{group_id}/{conversation_id}"
      )

      MockSlack.respond("chat.postMessage", %{
        "ok" => true,
        "channel" => "C-handover",
        "ts" => "70.200"
      })

      params = %{
        "conversation_id" => conversation_id,
        "channel" => "C-handover",
        "thread_ts" => "70.100"
      }

      assert {:ok,
              %{
                "conversation_id" => ^conversation_id,
                "participant_id" => participant_id,
                "channel" => "C-handover",
                "thread_ts" => "70.100",
                "binding_status" => "created"
              }} =
               call(
                 router_id,
                 "slack",
                 "slack.bind_thread_to_task",
                 connect_id,
                 params,
                 %{"tool_call_id" => "bind-slack-task-thread"}
               )

      assert Ids.valid_participant_id?(participant_id)

      binding_key =
        Keys.ctl_im_slack_thread_binding(
          group_id,
          connect_id,
          "C-handover",
          "70.100"
        )

      assert {:ok,
              %{
                "version" => 3,
                "binding_type" => "task",
                "binding_status" => "active",
                "conversation_id" => ^conversation_id,
                "participant_id" => ^participant_id
              }} = SalixStore.CasRecord.get(binding_key)

      route_key =
        Keys.ctl_im_slack_thread_route_owner(
          group_id,
          "T1",
          "C-handover",
          "70.100000"
        )

      assert {:ok, %{"schema" => "comma.slack-thread-route-owner.v4", "owner" => "task"}} =
               SalixStore.CasRecord.get(route_key)

      assert {:ok, %{"participants" => participants}} =
               Conversations.list_group_conversation_participants(group_id, conversation_id)

      assert %{
               "participant_id" => ^participant_id,
               "actor_type" => "provider",
               "provider" => "slack",
               "role_label" => "slack_thread",
               "payload" => %{
                 "connect_id" => ^connect_id,
                 "channel_id" => "C-handover",
                 "thread_ts" => "70.100"
               }
             } = Enum.find(participants, &(&1["participant_id"] == participant_id))

      expected_url =
        "https://teams.example.test/tasks/#{tenant}/#{group_id}/#{conversation_id}"

      expected_fallback = "Task Own the Slack handover: #{expected_url}"

      assert eventually(fn ->
               Enum.any?(MockSlack.requests("chat.postMessage"), fn request ->
                 request.params["channel"] == "C-handover" and
                   request.params["thread_ts"] == "70.100" and
                   request.params["text"] == expected_fallback and
                   conversation_link_card?(
                     request,
                     "Own the Slack handover",
                     expected_url
                   )
               end)
             end)

      assert {:ok, %{"binding_status" => "exists", "participant_id" => ^participant_id}} =
               call(
                 router_id,
                 "slack",
                 "slack.bind_thread_to_task",
                 connect_id,
                 params,
                 %{"tool_call_id" => "bind-slack-task-thread-retry"}
               )

      assert eventually(fn -> length(MockSlack.requests("chat.postMessage")) == 1 end)

      assert {:ok, %{"binding_status" => "binding"}} =
               SalixStore.CasRecord.update(
                 binding_key,
                 fn current -> Map.put(current, "binding_status", "binding") end,
                 create: false
               )

      connect =
        case SalixIM.ProviderConnects.get_active_connect_by_id(group_id, connect_id, "slack") do
          {:ok, connect} -> connect
        end

      follow_up =
        slack_envelope("Ev-task-thread-follow-up", %{
          "type" => "message",
          "user" => "U-requester",
          "user_profile" => %{"display_name" => "Task Requester"},
          "text" => "This must go straight to the existing Task.",
          "channel" => "C-handover",
          "channel_type" => "channel",
          "ts" => "70.300",
          "thread_ts" => "70.100"
        })

      follow_up_raw = Jason.encode!(follow_up)

      # Task ownership selects the destination; it cannot turn an instruction
      # explicitly addressed to somebody else into input for this Task.
      incident_trigger = @incident_trigger

      other_recipient =
        follow_up
        |> Map.put("event_id", "Ev-task-thread-other-recipient")
        |> put_in(["event", "text"], incident_trigger["text"])
        |> put_in(["event", "blocks"], incident_trigger["blocks"])
        |> put_in(["event", "ts"], "70.299")

      other_raw = Jason.encode!(other_recipient)

      assert {:error, :ignored} =
               SalixIM.ProviderHTTP.handle_slack_event(
                 connect,
                 other_recipient,
                 sign_slack_body(other_raw, "task-card-signing-secret"),
                 other_raw
               )

      assert {:ok, task_messages} =
               Conversations.list_group_conversation_messages(group_id, conversation_id,
                 limit: 20
               )

      refute Enum.any?(task_messages, fn message ->
               message["source_message_id"] ==
                 "im_provider:slack:#{connect_id}:Ev-task-thread-other-recipient"
             end)

      refute_received {:agent_delivery, ^worker_id, _, _}

      assert {:ok, :accepted} =
               SalixIM.ProviderHTTP.handle_slack_event(
                 connect,
                 follow_up,
                 sign_slack_body(follow_up_raw, "task-card-signing-secret"),
                 follow_up_raw
               )

      assert MockSlack.requests("conversations.replies") == []

      assert eventually(fn ->
               case Conversations.list_group_conversation_messages(
                      group_id,
                      conversation_id,
                      limit: 20
                    ) do
                 {:ok, messages} ->
                   Enum.any?(messages, fn message ->
                     message["source_message_id"] ==
                       "im_provider:slack:#{connect_id}:Ev-task-thread-follow-up" and
                       message["participant_id"] == participant_id and
                       message["actor_type"] == "provider_user" and
                       message["user_id"] == "U-requester"
                   end)

                 _ ->
                   false
               end
             end)

      settle_receive({:agent_delivery, ^worker_id, follow_up_payload, _follow_up_opts})
      assert follow_up_payload.content == "This must go straight to the existing Task."

      broadcast_follow_up =
        slack_envelope("Ev-task-thread-broadcast-follow-up", %{
          "type" => "message",
          "subtype" => "thread_broadcast",
          "user" => "U-requester",
          "text" => "This broadcast reply still belongs to the Task.",
          "channel" => "C-handover",
          "channel_type" => "channel",
          "ts" => "70.325",
          "thread_ts" => "70.100"
        })

      broadcast_raw = Jason.encode!(broadcast_follow_up)

      assert {:ok, :accepted} =
               SalixIM.ProviderHTTP.handle_slack_event(
                 connect,
                 broadcast_follow_up,
                 sign_slack_body(broadcast_raw, "task-card-signing-secret"),
                 broadcast_raw
               )

      broadcast_source_id =
        "im_provider:slack:#{connect_id}:Ev-task-thread-broadcast-follow-up"

      assert eventually(fn ->
               case Conversations.list_group_conversation_messages(
                      group_id,
                      conversation_id,
                      limit: 20
                    ) do
                 {:ok, messages} ->
                   Enum.any?(messages, fn message ->
                     message["source_message_id"] == broadcast_source_id and
                       message["participant_id"] == participant_id and
                       SalixIM.ConversationMessage.text_content(message["content"]) ==
                         "This broadcast reply still belongs to the Task."
                   end)

                 _ ->
                   false
               end
             end)

      settle_receive({:agent_delivery, ^worker_id, broadcast_payload, _broadcast_opts})
      assert broadcast_payload.content == "This broadcast reply still belongs to the Task."

      mentioned_follow_up =
        slack_envelope("Ev-task-thread-mentioned-follow-up", %{
          "type" => "app_mention",
          "user" => "U-requester",
          "text" => "<@Ubot> This mention still belongs to the Task.",
          "channel" => "C-handover",
          "channel_type" => "channel",
          "ts" => "70.350",
          "thread_ts" => "70.100"
        })

      mentioned_raw = Jason.encode!(mentioned_follow_up)

      assert {:ok, :accepted} =
               SalixIM.ProviderHTTP.handle_slack_event(
                 connect,
                 mentioned_follow_up,
                 sign_slack_body(mentioned_raw, "task-card-signing-secret"),
                 mentioned_raw
               )

      mentioned_source_id =
        "im_provider:slack:#{connect_id}:Ev-task-thread-mentioned-follow-up"

      assert eventually(fn ->
               case Conversations.list_group_conversation_messages(
                      group_id,
                      conversation_id,
                      limit: 20
                    ) do
                 {:ok, messages} ->
                   Enum.any?(messages, fn message ->
                     message["source_message_id"] == mentioned_source_id and
                       message["participant_id"] == participant_id and
                       SalixIM.ConversationMessage.text_content(message["content"]) ==
                         "This mention still belongs to the Task."
                   end)

                 _ ->
                   false
               end
             end)

      settle_receive({:agent_delivery, ^worker_id, mentioned_payload, _mentioned_opts})
      assert mentioned_payload.content == "This mention still belongs to the Task."

      assert {:ok, %{"data" => conversations}} =
               Conversations.list_group_conversations(group_id, limit: 100)

      assert Enum.count(conversations, &(&1["kind"] == "agent_task")) == 1

      {:ok, router_session_id} =
        SalixIM.ProviderConnects.agent_group_router_session_id(router_id, group_id)

      case SalixAgent.TestSupport.SessionData.read(router_id, router_session_id) do
        {:ok, session} ->
          refute Enum.any?(session.messages, fn message ->
                   message.source_message_id in [
                     "im_provider:slack:#{connect_id}:Ev-task-thread-follow-up",
                     broadcast_source_id,
                     mentioned_source_id
                   ]
                 end)

        {:error, :not_found} ->
          :ok
      end

      MockSlack.respond("chat.postMessage", %{
        "ok" => true,
        "channel" => "C-handover",
        "ts" => "70.400"
      })

      assert {:ok, %{"inserted" => true} = worker_reply} =
               ConversationServer.append_group_conversation_agent_message(
                 group_id,
                 conversation_id,
                 worker_id,
                 %{
                   "client_request_id" => "task-thread-worker-reply",
                   "content" => "Worker reply through the Task participant."
                 }
               )

      assert eventually(fn ->
               Enum.any?(MockSlack.requests("chat.postMessage"), fn request ->
                 request.params["channel"] == "C-handover" and
                   request.params["thread_ts"] == "70.100" and
                   request.params["text"] == "Worker reply through the Task participant."
               end)
             end)

      assert Ids.valid_message_id?(worker_reply["message_id"])
    end

    test "Stage A stale ingress cannot complete across a future unbinding fence", %{
      tenant: tenant,
      group_id: group_id,
      agent_id: router_id,
      slack_connect_id: connect_id
    } do
      {conversation_id, _worker_id} =
        create_slack_task!(tenant, group_id, router_id, "Fence a stale Stage A ingress")

      params = %{
        "conversation_id" => conversation_id,
        "channel" => "C-future-unbinding-fence",
        "thread_ts" => "73.300"
      }

      assert {:ok, %{"participant_id" => participant_id}} =
               call(router_id, "slack", "slack.bind_thread_to_task", connect_id, params)

      binding_key =
        Keys.ctl_im_slack_thread_binding(
          group_id,
          connect_id,
          params["channel"],
          params["thread_ts"]
        )

      assert {:ok, %{"binding_token" => binding_token}} =
               SalixStore.CasRecord.get(binding_key)

      {:ok, connect} =
        SalixIM.ProviderConnects.get_active_connect_by_id(group_id, connect_id, "slack")

      ingress = SalixIM.Provider.Slack.ConversationIngress
      parent = SystemsRuntime.Proc.self()

      stale_ingress =
        SystemsRuntime.Proc.spawn(fn ->
          SystemsRuntime.Proc.receive do
            :go ->
              result =
                ingress.append_task_thread_message(connect, %{
                  "channel_id" => params["channel"],
                  "thread_ts" => params["thread_ts"],
                  "message_ts" => "73.350",
                  "source_message_id" => "stage-a-stale-ingress-after-fence",
                  "user_id" => "U-requester",
                  "content" => "This stale request must not cross the future fence."
                })

              SystemsRuntime.Proc.send(parent, {:stage_a_stale_ingress_result, result})
          end
        end)

      # The stale ingress has read the active binding when its completion
      # write parks; the write lands only after the fence below.
      :ok = SalixStore.S3.Fake.set_fault_for(stale_ingress, {:pause, :put, binding_key})

      on_exit(fn ->
        if SalixStore.S3.Fake.paused?(), do: SalixStore.S3.Fake.release_pause()
      end)

      SystemsRuntime.Proc.send(stale_ingress, :go)
      :ok = SalixStore.S3.Fake.await_pause()

      assert {:ok,
              %{
                "version" => 4,
                "binding_status" => "unbinding",
                "binding_token" => ^binding_token
              }} =
               SalixStore.CasRecord.update(
                 binding_key,
                 fn current ->
                   current
                   |> Map.put("version", 4)
                   |> Map.put("binding_status", "unbinding")
                   |> Map.put("updated_at", SystemsClock.system_time(:millisecond))
                 end,
                 create: false
               )

      assert {:ok, %{"state" => "inactive"}} =
               ConversationServer.deactivate_group_conversation_participant_if_payload(
                 group_id,
                 conversation_id,
                 participant_id,
                 %{"task_thread_binding_token" => binding_token}
               )

      :ok = SalixStore.S3.Fake.release_pause()

      settle_receive({:stage_a_stale_ingress_result, stale_result})

      assert stale_result in [
               {:error, :slack_thread_binding_conflict},
               {:error, :participant_binding_generation_mismatch},
               {:error, {:bad_request, "message participant target is missing or invalid"}}
             ]

      assert {:ok,
              %{
                "version" => 4,
                "binding_status" => "unbinding",
                "binding_token" => ^binding_token
              }} = SalixStore.CasRecord.get(binding_key)

      assert {:ok, %{"state" => "inactive"}} =
               Conversations.get_group_conversation_participant(
                 group_id,
                 conversation_id,
                 participant_id
               )

      assert {:ok, messages} =
               Conversations.list_group_conversation_messages(group_id, conversation_id,
                 limit: 20
               )

      refute Enum.any?(
               messages,
               &(&1["source_message_id"] == "stage-a-stale-ingress-after-fence")
             )
    end

    test "Stage A delivery fence waits for in-flight Slack IO and suppresses queued output", %{
      tenant: tenant,
      group_id: group_id,
      agent_id: router_id,
      slack_connect_id: connect_id
    } do
      parent = SystemsRuntime.Proc.self()

      {conversation_id, worker_id} =
        create_slack_task!(tenant, group_id, router_id, "Fence Task output delivery")

      params = %{
        "conversation_id" => conversation_id,
        "channel" => "C-delivery-fence",
        "thread_ts" => "73.500"
      }

      assert {:ok, %{"participant_id" => participant_id}} =
               call(router_id, "slack", "slack.bind_thread_to_task", connect_id, params)

      binding_key =
        Keys.ctl_im_slack_thread_binding(
          group_id,
          connect_id,
          params["channel"],
          params["thread_ts"]
        )

      assert {:ok, %{"binding_token" => binding_token}} =
               SalixStore.CasRecord.get(binding_key)

      MockSlack.respond_with("chat.postMessage", fn request ->
        SystemsRuntime.Proc.send(
          parent,
          {:task_thread_delivery_started, SystemsRuntime.Proc.self(), request}
        )

        SystemsRuntime.Proc.receive do
          :release_task_thread_delivery ->
            %{"ok" => true, "channel" => request.params["channel"], "ts" => "73.510"}
        end
      end)

      assert {:ok, %{"inserted" => true}} =
               ConversationServer.append_group_conversation_agent_message(
                 group_id,
                 conversation_id,
                 worker_id,
                 %{
                   "content" => "First output is already in flight.",
                   "client_request_id" => "task-thread-delivery-fence-first"
                 }
               )

      settle_receive({:task_thread_delivery_started, request_pid, first_request})
      assert first_request.params["channel"] == params["channel"]
      assert first_request.params["thread_ts"] == params["thread_ts"]

      assert {:ok, %{"inserted" => true}} =
               ConversationServer.append_group_conversation_agent_message(
                 group_id,
                 conversation_id,
                 worker_id,
                 %{
                   "content" => "Second queued output must be fenced.",
                   "client_request_id" => "task-thread-delivery-fence-second"
                 }
               )

      delivery_fence =
        "delivery-fence-" <>
          Base.url_encode64(SystemsRuntime.Proc.random_bytes(18), padding: false)

      assert {:ok, %{"barrier_status" => "pending", "cutoff_seq" => cutoff_seq}} =
               ConversationServer.fence_group_conversation_provider_participant_incarnation(
                 group_id,
                 conversation_id,
                 participant_id,
                 %{"task_thread_binding_token" => binding_token},
                 delivery_fence
               )

      assert is_integer(cutoff_seq) and cutoff_seq > 0
      assert length(MockSlack.requests("chat.postMessage")) == 1

      SystemsRuntime.Proc.send(request_pid, :release_task_thread_delivery)

      assert eventually(
               fn ->
                 match?(
                   {:ok,
                    %{
                      "barrier_status" => "settled",
                      "delivery_fence" => ^delivery_fence
                    }},
                   ConversationServer.fence_group_conversation_provider_participant_incarnation(
                     group_id,
                     conversation_id,
                     participant_id,
                     %{"task_thread_binding_token" => binding_token},
                     delivery_fence
                   )
                 )
               end,
               1200
             )

      SystemsClock.sleep(100)

      assert [only_request] = MockSlack.requests("chat.postMessage")
      assert only_request.params["text"] == "First output is already in flight."

      assert {:ok,
              %{
                "state" => "inactive",
                "delivery_cursor_seq" => ^cutoff_seq,
                "task_thread_delivery_fence" => %{
                  "fence_token" => ^delivery_fence,
                  "binding_token" => ^binding_token
                }
              }} =
               Conversations.get_group_conversation_participant(
                 group_id,
                 conversation_id,
                 participant_id
               )
    end

    test "Task thread handover is create-once and cannot replace another owner", %{
      tenant: tenant,
      group_id: group_id,
      agent_id: router_id,
      slack_connect_id: connect_id
    } do
      {first_conversation_id, first_worker_id} =
        create_slack_task!(tenant, group_id, router_id, "First Task owns the thread")

      {second_conversation_id, _second_worker_id} =
        create_slack_task!(tenant, group_id, router_id, "Second Task cannot steal it")

      params = %{
        "conversation_id" => first_conversation_id,
        "channel" => "C-binding-conflict",
        "thread_ts" => "71.100"
      }

      assert {:ok, %{"conversation_id" => ^first_conversation_id}} =
               call(
                 router_id,
                 "slack",
                 "slack.bind_thread_to_task",
                 connect_id,
                 params
               )

      assert {:error, reason} =
               call(
                 router_id,
                 "slack",
                 "slack.bind_thread_to_task",
                 connect_id,
                 %{params | "conversation_id" => second_conversation_id}
               )

      assert inspect(reason) =~ "slack_thread_binding_conflict"

      assert {:ok, %{"conversation_id" => ^first_conversation_id}} =
               SalixStore.CasRecord.get(
                 Keys.ctl_im_slack_thread_binding(
                   group_id,
                   connect_id,
                   "C-binding-conflict",
                   "71.100"
                 )
               )

      assert {:ok, %{"participants" => second_participants}} =
               Conversations.list_group_conversation_participants(
                 group_id,
                 second_conversation_id
               )

      refute Enum.any?(second_participants, fn participant ->
               participant["role_label"] == "slack_thread" and
                 get_in(participant, ["payload", "channel_id"]) == "C-binding-conflict"
             end)

      {:ok, connect} =
        SalixIM.ProviderConnects.get_active_connect_by_id(group_id, connect_id, "slack")

      assert {:ok, worker_binding_result} =
               SalixIM.Provider.Slack.ConversationIngress.append_worker_thread_message(
                 connect,
                 first_worker_id,
                 %{
                   "channel_id" => "C-worker-owned",
                   "thread_ts" => "72.100",
                   "message_ts" => "72.100",
                   "source_message_id" => "worker-owned-thread-root",
                   "user_id" => "U-requester",
                   "content" => "Worker-owned thread"
                 }
               )

      assert worker_binding_result["conversation_id"] != first_conversation_id

      assert {:error, worker_conflict} =
               call(
                 router_id,
                 "slack",
                 "slack.bind_thread_to_task",
                 connect_id,
                 %{
                   "conversation_id" => first_conversation_id,
                   "channel" => "C-worker-owned",
                   "thread_ts" => "72.100"
                 }
               )

      assert inspect(worker_conflict) =~ "slack_thread_binding_conflict"
    end

    test "Router-owned native Task card follows the authoritative plain-Task lifecycle", %{
      tenant: tenant,
      group_id: group_id,
      agent_id: router_id,
      slack_connect_id: connect_id
    } do
      {conversation_id, worker_id} =
        create_slack_task!(tenant, group_id, router_id, "Build the launch report",
          command: "Build the launch report with revenue, adoption, and launch-risk findings."
        )

      MockSlack.respond("chat.postMessage", %{
        "ok" => true,
        "channel" => "C-task",
        "ts" => "10.100"
      })

      MockSlack.respond("chat.update", %{
        "ok" => true,
        "channel" => "C-task",
        "ts" => "10.100"
      })

      params = %{
        "conversation_id" => conversation_id,
        "channel" => "C-task",
        "thread_ts" => "10.000"
      }

      assert {:ok, %{"delivery_status" => "queued", "task_id" => task_id}} =
               call(
                 router_id,
                 "slack",
                 "slack.post_task_card",
                 connect_id,
                 params,
                 %{"tool_call_id" => "task-card-create"}
               )

      assert {:error, :not_found} =
               SalixStore.CasRecord.get(
                 Keys.ctl_im_slack_thread_binding(
                   group_id,
                   connect_id,
                   params["channel"],
                   params["thread_ts"]
                 )
               )

      assert eventually(fn -> length(MockSlack.requests("chat.postMessage")) == 1 end)
      initial = MockSlack.last_request("chat.postMessage") |> slack_task_card_from_request()
      assert initial["type"] == "task_card"
      assert initial["task_id"] == task_id
      assert initial["title"] == "Build the launch report"
      assert initial["status"] == "in_progress"

      assert slack_task_card_details(initial) == "Model: Comma"
      refute Map.has_key?(initial, "output")

      participant = task_card_participant!(group_id, conversation_id)

      assert eventually(fn ->
               case Conversations.get_group_conversation_participant(
                      group_id,
                      conversation_id,
                      participant["participant_id"]
                    ) do
                 {:ok, current} -> get_in(current, ["payload", "message_ts"]) == "10.100"
                 _ -> false
               end
             end)

      assert {:ok, %{"delivery_status" => "exists", "task_id" => ^task_id}} =
               call(
                 router_id,
                 "slack",
                 "slack.post_task_card",
                 connect_id,
                 params,
                 %{"tool_call_id" => "task-card-create"}
               )

      assert {:ok, %{"inserted" => true}} =
               ConversationServer.append_group_conversation_agent_message(
                 group_id,
                 conversation_id,
                 worker_id,
                 %{
                   "content" => "Drafted the data section.",
                   "client_request_id" => "task-card-progress"
                 }
               )

      assert eventually(fn ->
               case List.last(MockSlack.requests("chat.update")) do
                 nil ->
                   false

                 request ->
                   card = slack_task_card_from_request(request)

                   card["status"] == "in_progress" and
                     slack_task_card_details(card) == "Model: Comma" and
                     slack_task_card_output(card) == "Drafted the data section."
               end
             end)

      assert {:ok, %{"inserted" => true}} =
               ConversationServer.append_group_conversation_agent_message(
                 group_id,
                 conversation_id,
                 worker_id,
                 %{
                   "content" => "The launch report is ready.",
                   "client_request_id" => "task-card-result"
                 }
               )

      assert {:ok, %{"status" => "ready_for_review", "updated_at" => review_version}} =
               ConversationServer.update_group_conversation(group_id, conversation_id, %{
                 "status" => "ready_for_review"
               })

      assert eventually(fn ->
               card =
                 MockSlack.requests("chat.update")
                 |> List.last()
                 |> slack_task_card_from_request()

               card["status"] == "complete" and
                 slack_task_card_output(card) == "The launch report is ready." and
                 slack_task_card_details(card) ==
                   "Model: Comma\n\nWorker: Drafted the data section."
             end)

      assert {:ok, %{"status" => "completed"}} =
               ConversationServer.accept_task_review(group_id, conversation_id, review_version)

      assert {:ok, %{"inserted" => true}} =
               ConversationServer.append_group_conversation_agent_message(
                 group_id,
                 conversation_id,
                 router_id,
                 %{
                   "content" => "Add an executive summary.",
                   "client_request_id" => "task-card-reopen"
                 }
               )

      assert {:ok, %{"status" => "completed"}} =
               Conversations.get_group_conversation(group_id, conversation_id)

      assert {:ok, %{"status" => "active"}} =
               ConversationServer.update_group_conversation(group_id, conversation_id, %{
                 "status" => "active"
               })

      assert eventually(fn ->
               case List.last(MockSlack.requests("chat.update")) do
                 nil ->
                   false

                 request ->
                   reopened = slack_task_card_from_request(request)

                   reopened["status"] == "in_progress" and
                     slack_task_card_details(reopened) ==
                       "Model: Comma\n\nWorker: Drafted the data section.\n\nWorker: The launch report is ready." and
                     slack_task_card_output(reopened) == "Add an executive summary."
               end
             end)

      assert length(MockSlack.requests("chat.postMessage")) == 1
    end

    test "Task-card publication errors name the failing precondition", %{
      tenant: tenant,
      group_id: group_id,
      agent_id: router_id,
      slack_connect_id: connect_id
    } do
      {conversation_id, _worker_id} =
        create_slack_task!(tenant, group_id, router_id, "Name the failing precondition")

      assert {:error,
              "channel and thread_ts are required, and thread_ts must be a Slack message timestamp"} =
               call(
                 router_id,
                 "slack",
                 "slack.post_task_card",
                 connect_id,
                 %{
                   "conversation_id" => conversation_id,
                   "channel" => "C-errors",
                   "thread_ts" => "not-a-timestamp"
                 },
                 %{"tool_call_id" => "task-card-bad-ts"}
               )

      user_chat_id = Ids.new_conversation_id()
      seed_group_conversation(group_id, router_id, %{"conversation_id" => user_chat_id})

      assert {:error, "conversation_id must identify a Task conversation in this group"} =
               call(
                 router_id,
                 "slack",
                 "slack.post_task_card",
                 connect_id,
                 %{
                   "conversation_id" => user_chat_id,
                   "channel" => "C-errors",
                   "thread_ts" => "15.000"
                 },
                 %{"tool_call_id" => "task-card-not-a-task"}
               )

      {:ok, other_delegator} =
        create_control_agent(
          %{
            "name" => "Foreign delegator #{SystemsRuntime.Proc.unique_integer([:positive])}",
            "group_id" => group_id,
            "role" => "worker"
          },
          tenant
        )

      {foreign_conversation_id, _foreign_worker} =
        create_slack_task!(tenant, group_id, other_delegator["agent_id"], "Foreign Task")

      assert {:error, "only the Router that created this Task can publish its Task card"} =
               call(
                 router_id,
                 "slack",
                 "slack.post_task_card",
                 connect_id,
                 %{
                   "conversation_id" => foreign_conversation_id,
                   "channel" => "C-errors",
                   "thread_ts" => "15.000"
                 },
                 %{"tool_call_id" => "task-card-foreign"}
               )
    end

    test "late Task card publication omits details for a same-title command and private text",
         %{
           tenant: tenant,
           group_id: group_id,
           agent_id: router_id,
           slack_connect_id: connect_id
         } do
      {conversation_id, worker_id} =
        create_slack_task!(tenant, group_id, router_id, "Keep filtered progress private")

      assert {:ok, %{"inserted" => true}} =
               ConversationServer.append_group_conversation_agent_message(
                 group_id,
                 conversation_id,
                 worker_id,
                 %{
                   "content" => "Private worker evidence must not leave Comma.",
                   "client_request_id" => "task-card-filtered-progress-before-publication",
                   "delivery_filter" => %{"participant_ids" => []}
                 }
               )

      MockSlack.respond("chat.postMessage", %{
        "ok" => true,
        "channel" => "C-filtered-progress",
        "ts" => "10.450"
      })

      assert {:ok, %{"delivery_status" => "queued"}} =
               call(
                 router_id,
                 "slack",
                 "slack.post_task_card",
                 connect_id,
                 %{
                   "conversation_id" => conversation_id,
                   "channel" => "C-filtered-progress",
                   "thread_ts" => "10.400"
                 },
                 %{"tool_call_id" => "task-card-filtered-progress-publication"}
               )

      # Full provider runs can keep the Participant owner busy for more than
      # the default two-second polling window before this late publication.
      assert eventually(fn -> length(MockSlack.requests("chat.postMessage")) == 1 end, 1200)
      card = MockSlack.last_request("chat.postMessage") |> slack_task_card_from_request()
      assert card["status"] == "in_progress"
      assert slack_task_card_details(card) == "Model: Comma"
      refute Map.has_key?(card, "output")
    end

    test "ambiguous Task-card evidence without a Slack message address cannot authorize a duplicate post",
         %{
           tenant: tenant,
           group_id: group_id,
           agent_id: router_id,
           slack_connect_id: connect_id
         } do
      {conversation_id, worker_id} =
        create_slack_task!(tenant, group_id, router_id, "Reject addressless card evidence")

      {:ok, writes} = Agent.start_link(fn -> 0 end)

      MockSlack.respond_with("chat.postMessage", fn request ->
        case Agent.get_and_update(writes, &{&1 + 1, &1 + 1}) do
          1 ->
            {500, %{"ok" => false, "error" => "internal_error"}}

          _ ->
            %{"ok" => true, "channel" => request.params["channel"], "ts" => "30.805"}
        end
      end)

      assert {:ok, %{"delivery_status" => "queued"}} =
               call(
                 router_id,
                 "slack",
                 "slack.post_task_card",
                 connect_id,
                 %{
                   "conversation_id" => conversation_id,
                   "channel" => "C-addressless-evidence",
                   "thread_ts" => "30.800"
                 },
                 %{"tool_call_id" => "task-card-addressless-evidence"}
               )

      assert eventually(fn -> Agent.get(writes, & &1) == 1 end, 1200)
      assert :ok = emit_task_card_metadata!("chat.postMessage", "")

      participant = task_card_participant!(group_id, conversation_id)

      {:ok, inspection_store} =
        SalixIM.ConversationParticipantStore.start_link(
          owner: SystemsRuntime.Proc.self(),
          group_id: group_id,
          conversation_id: conversation_id,
          participant_id: participant["participant_id"]
        )

      assert eventually(fn ->
               active_provider_receipts(inspection_store) ==
                 {:ok, []}
             end)

      assert {:ok, %{"inserted" => true}} =
               ConversationServer.append_group_conversation_agent_message(
                 group_id,
                 conversation_id,
                 worker_id,
                 %{
                   "content" => "This progress must not create a second card.",
                   "client_request_id" => "task-card-addressless-progress"
                 }
               )

      SystemsClock.sleep(250)
      assert Agent.get(writes, & &1) == 1
    end

    test "deleting the current Task card repairs it through the existing delivery path", %{
      tenant: tenant,
      group_id: group_id,
      agent_id: router_id,
      slack_connect_id: connect_id
    } do
      {conversation_id, _worker_id} =
        create_slack_task!(tenant, group_id, router_id, "Repair the deleted Task card")

      {:ok, posts} = Agent.start_link(fn -> 0 end)

      MockSlack.respond_with("chat.postMessage", fn request ->
        ts = if Agent.get_and_update(posts, &{&1 + 1, &1 + 1}) == 1, do: "31.000", else: "31.100"
        %{"ok" => true, "channel" => request.params["channel"], "ts" => ts}
      end)

      MockSlack.respond("chat.update", %{"ok" => false, "error" => "message_not_found"})

      assert {:ok, %{"delivery_status" => "queued"}} =
               call(
                 router_id,
                 "slack",
                 "slack.post_task_card",
                 connect_id,
                 %{
                   "conversation_id" => conversation_id,
                   "channel" => "C-deleted-task-card",
                   "thread_ts" => "30.950"
                 },
                 %{"tool_call_id" => "deleted-task-card-repair"}
               )

      assert eventually(fn ->
               participant = task_card_participant!(group_id, conversation_id)
               get_in(participant, ["payload", "message_ts"]) == "31.000"
             end)

      assert :ok =
               emit_task_card_metadata!("chat.postMessage", "31.000",
                 kind: "message_metadata_deleted"
               )

      assert eventually(fn -> Agent.get(posts, & &1) == 2 end)
      assert length(MockSlack.requests("chat.update")) == 1

      assert eventually(fn ->
               participant = task_card_participant!(group_id, conversation_id)
               get_in(participant, ["payload", "message_ts"]) == "31.100"
             end)
    end

    test "product-owned Slack card APIs render blocks from semantic data", %{
      agent_id: agent_id,
      slack_connect_id: connect_id
    } do
      cards = [
        {"slack.post_map_card",
         %{
           "channel" => "C9",
           "location" => "Shanghai",
           "latitude" => "31.2304",
           "longitude" => "121.4737"
         }, "Map:", ["card"]},
        {"slack.post_stock_card",
         %{
           "channel" => "C9",
           "symbol" => "AAPL",
           "price" => "231.40",
           "currency" => "USD",
           "change" => "+2.40",
           "open" => 229.0,
           "high" => 233.2,
           "low" => 228.7,
           "price_history" => [
             %{"label" => "09:30", "value" => 229.0},
             %{"label" => "16:00", "value" => 231.4}
           ]
         }, "Stock:", ["container"]},
        {"slack.post_weather_card",
         %{
           "channel" => "C9",
           "location" => "Shanghai",
           "condition" => "Light rain",
           "temperature" => "27",
           "unit" => "C",
           "hourly_forecast" => [
             %{"time" => "Now", "temperature" => 27},
             %{"time" => "14:00", "temperature" => 28}
           ],
           "daily_forecast" => [
             %{"day" => "Today", "condition" => "Rain", "high" => 30, "low" => 24}
           ]
         }, "Weather:", ["container"]}
      ]

      for {api, params, fallback_prefix, expected_types} <- cards do
        refute Map.has_key?(params, "blocks")

        MockSlack.respond("chat.postMessage", %{
          "ok" => true,
          "channel" => "C9",
          "ts" => "1.2"
        })

        assert {:ok, %{"channel" => "C9", "ts" => "1.2"}} =
                 call(agent_id, "slack", api, connect_id, params)

        request = MockSlack.last_request("chat.postMessage")
        assert String.starts_with?(request.params["text"], fallback_prefix)
        assert Enum.map(Jason.decode!(request.params["blocks"]), & &1["type"]) == expected_types
        assert request.params["unfurl_links"] == "false"
        assert request.params["unfurl_media"] == "false"
      end
    end

    test "Slack card fallback neutralizes mention control syntax", %{
      agent_id: agent_id,
      slack_connect_id: connect_id
    } do
      MockSlack.respond("chat.postMessage", %{
        "ok" => true,
        "channel" => "C9",
        "ts" => "1.2"
      })

      assert {:ok, _} =
               call(agent_id, "slack", "slack.post_map_card", connect_id, %{
                 "channel" => "C9",
                 "location" => "Meet <@U012AB3CD> & team",
                 "latitude" => 31.2304,
                 "longitude" => 121.4737
               })

      request = MockSlack.last_request("chat.postMessage")

      assert request.params["text"] ==
               "Map: Meet &lt;@U012AB3CD&gt; &amp; team — 31.2304, 121.4737"

      refute request.params["text"] =~ "<@U012AB3CD>"
    end

    test "slack.reply_message renders standard Markdown and returns {channel, ts}", %{
      agent_id: agent_id,
      group_id: group_id,
      slack_connect_id: connect_id
    } do
      MockSlack.respond("chat.postMessage", %{"ok" => true, "channel" => "C9", "ts" => "1.2"})

      markdown =
        "# Status\n\nhello **bold**\n\n" <>
          "| Owner | State |\n| --- | --- |\n| <@U012ABCDEF> | Ready |"

      assert {:ok, %{"channel" => "C9", "ts" => "1.2"}} =
               call(agent_id, "slack", "slack.reply_message", connect_id, %{
                 "channel" => "C9",
                 "text" => markdown,
                 "thread_ts" => "1.0",
                 "metadata" => %{
                   "event_type" => "salix_conversation_delivery",
                   "event_payload" => %{"operation_ref" => "groupconv-delivery-test"}
                 }
               })

      req = MockSlack.last_request("chat.postMessage")
      assert req.auth == "Bearer xoxb-test"
      assert req.content_type =~ "application/x-www-form-urlencoded"
      assert req.params["channel"] == "C9"
      assert req.params["text"] == markdown
      assert req.params["thread_ts"] == "1.0"
      refute Map.has_key?(req.params, "unfurl_links")
      refute Map.has_key?(req.params, "unfurl_media")

      assert [
               %{"type" => "header", "text" => %{"text" => "Status"}},
               %{"type" => "rich_text", "elements" => [%{"elements" => prose}]},
               %{"type" => "table"} = table
             ] = Jason.decode!(req.params["blocks"])

      assert prose == [
               %{"type" => "text", "text" => "hello "},
               %{"type" => "text", "text" => "bold", "style" => %{"bold" => true}}
             ]

      assert get_in(table, [
               "rows",
               Access.at(1),
               Access.at(0),
               "elements",
               Access.at(0),
               "elements"
             ]) == [
               %{"type" => "user", "user_id" => "U012ABCDEF"}
             ]

      assert Jason.decode!(req.params["metadata"]) == %{
               "event_type" => "salix_conversation_delivery",
               "event_payload" => %{"operation_ref" => "groupconv-delivery-test"}
             }

      assert SalixStore.SlackRouterThreadParticipations.participating?(
               group_id,
               connect_id,
               "T1",
               "Ubot",
               "C9",
               "1.0"
             )
    end

    test "provider conversation delivery sends Slack message once across repeated drains", %{
      agent_id: agent_id,
      group_id: group_id,
      slack_connect_id: connect_id
    } do
      conversation_id = Ids.new_conversation_id()
      message_id = Ids.new_message_id()
      participant_id = Ids.new_participant_id()

      seed_group_conversation(group_id, agent_id, %{"conversation_id" => conversation_id})

      delivery = %{
        "delivery_id" => "#{group_id}:#{conversation_id}:#{message_id}:#{participant_id}",
        "status" => "pending",
        "agent_group_id" => group_id,
        "conversation_id" => conversation_id,
        "message_id" => message_id,
        "participant_id" => participant_id,
        "participant_actor_type" => "provider",
        "participant_provider" => "slack",
        "participant_payload" => %{
          "connect_id" => connect_id,
          "channel_id" => "C-once",
          "thread_ts" => "10.000"
        },
        "operation_ref" => "groupconv-delivery-once",
        "message_content" => [%{"type" => "text", "text" => "send once"}],
        "message_created_at" => SystemsClock.system_time(:millisecond)
      }

      {participant_id, message_id} =
        put_delivery!(group_id, conversation_id, participant_id, delivery)

      MockSlack.respond("chat.postMessage", %{
        "ok" => true,
        "channel" => "C-once",
        "ts" => "10.100"
      })

      delivered =
        wake_delivery_and_wait!(
          group_id,
          conversation_id,
          participant_id,
          message_id,
          "delivered"
        )

      assert delivered["delivery"]["delivery_result"] == %{
               "channel" => "C-once",
               "ts" => "10.100"
             }

      assert :ok =
               ConversationServer.wake_participant(group_id, conversation_id, participant_id)

      assert [request] = MockSlack.requests("chat.postMessage")
      assert request.params["channel"] == "C-once"
      assert request.params["thread_ts"] == "10.000"
      assert request.params["text"] == "send once"

      metadata = Jason.decode!(request.params["metadata"])
      assert metadata["event_type"] == "salix_conversation_delivery"
      assert metadata["event_payload"]["operation_ref"] =~ "groupconv-delivery-"
      refute Map.has_key?(metadata["event_payload"], "conversation_id")
      refute Map.has_key?(metadata["event_payload"], "message_id")
      refute Map.has_key?(metadata["event_payload"], "participant_id")
    end

    test "provider conversation delivery shares a file with a Slack-compatible Markdown comment",
         %{
           agent_id: agent_id,
           group_id: group_id,
           slack_connect_id: connect_id
         } do
      conversation_id = Ids.new_conversation_id()
      message_id = Ids.new_message_id()
      participant_id = Ids.new_participant_id()
      file_path = "/attachments/result.txt"

      seed_group_conversation(group_id, agent_id, %{"conversation_id" => conversation_id})
      seed_agent_vfs(agent_id, %{file_path => "VISIBLE-RESULT-BYTES"})

      delivery = %{
        "delivery_id" => "#{group_id}:#{conversation_id}:#{message_id}:#{participant_id}",
        "status" => "pending",
        "agent_group_id" => group_id,
        "conversation_id" => conversation_id,
        "message_id" => message_id,
        "participant_id" => participant_id,
        "participant_actor_type" => "provider",
        "participant_provider" => "slack",
        "participant_payload" => %{
          "connect_id" => connect_id,
          "channel_id" => "C-file-block",
          "thread_ts" => "20.000"
        },
        "operation_ref" => "groupconv-delivery-file-block",
        "source_agent_id" => agent_id,
        "message_content" => [
          %{
            "type" => "text",
            "text" => "Here is the **report**.\n\n- Revenue ready\n- Risk ready"
          },
          %{"type" => "file", "path" => file_path, "title" => "result.txt"}
        ],
        "message_created_at" => SystemsClock.system_time(:millisecond)
      }

      {participant_id, message_id} =
        put_delivery!(group_id, conversation_id, participant_id, delivery)

      base =
        :salix_im
        |> SystemsRuntime.fetch_env!(:slack_api_base_url)
        |> String.replace_suffix("/api", "")

      MockSlack.respond("files.getUploadURLExternal", %{
        "ok" => true,
        "upload_url" => base <> "/upload/F-delivery",
        "file_id" => "F-delivery"
      })

      MockSlack.respond("files.completeUploadExternal", %{
        "ok" => true,
        "files" => [%{"id" => "F-delivery", "name" => "result.txt"}]
      })

      diagnostic =
        wake_delivery_and_wait!(
          group_id,
          conversation_id,
          participant_id,
          message_id,
          "delivered"
        )

      delivered = diagnostic["delivery"]["delivery_result"]

      assert delivered["uploaded_files"] == [
               %{
                 "files" => [%{"id" => "F-delivery", "name" => "result.txt"}],
                 "path" => file_path
               }
             ]

      assert MockSlack.requests("chat.postMessage") == []

      [upload_request] = MockSlack.requests("external_upload")
      assert upload_request.raw == "VISIBLE-RESULT-BYTES"

      complete_request = MockSlack.last_request("files.completeUploadExternal")
      assert complete_request.params["channel_id"] == "C-file-block"
      assert complete_request.params["thread_ts"] == "20.000"
      refute Map.has_key?(complete_request.params, "initial_comment")
      blocks = Jason.decode!(complete_request.params["blocks"])

      assert {:ok, %{blocks: ^blocks}} =
               SalixIM.Provider.Slack.MessageRenderer.render(
                 "Here is the **report**.\n\n- Revenue ready\n- Risk ready"
               )

      assert Jason.decode!(complete_request.params["files"]) == [
               %{"id" => "F-delivery", "title" => "result.txt"}
             ]

      assert SalixStore.SlackRouterThreadParticipations.participating?(
               group_id,
               connect_id,
               "T1",
               "Ubot",
               "C-file-block",
               "20.000"
             )
    end

    # A delivery without an operation_ref cannot be verified against Slack, so
    # it settles as unknown and is never resent, whether it never started or
    # went stale mid-send.
    for {name, status, started_ago_ms, channel_id, thread_ts} <- [
          {"pending provider delivery without operation ref is marked unknown", "pending", nil,
           "C-legacy-pending", "40.000"},
          {"stale provider delivery without operation ref is marked unknown without resend",
           "delivering", 180_000, "C-stale-no-op-ref", "41.000"}
        ] do
      @status status
      @tag started_ago_ms: started_ago_ms
      @channel_id channel_id
      @thread_ts thread_ts
      test name,
           %{
             agent_id: agent_id,
             group_id: group_id,
             slack_connect_id: connect_id,
             started_ago_ms: started_ago_ms
           } do
        conversation_id = Ids.new_conversation_id()
        message_id = Ids.new_message_id()
        participant_id = Ids.new_participant_id()
        now = SystemsClock.system_time(:millisecond)

        seed_group_conversation(group_id, agent_id, %{"conversation_id" => conversation_id})

        delivery =
          %{
            "delivery_id" => "#{group_id}:#{conversation_id}:#{message_id}:#{participant_id}",
            "status" => @status,
            "agent_group_id" => group_id,
            "conversation_id" => conversation_id,
            "message_id" => message_id,
            "participant_id" => participant_id,
            "participant_actor_type" => "provider",
            "participant_provider" => "slack",
            "participant_payload" => %{
              "connect_id" => connect_id,
              "channel_id" => @channel_id,
              "thread_ts" => @thread_ts
            },
            "message_content" => [%{"type" => "text", "text" => "missing operation ref"}],
            "message_created_at" => now
          }
          |> then(fn delivery ->
            if started_ago_ms,
              do: Map.put(delivery, "delivery_started_at", now - started_ago_ms),
              else: delivery
          end)

        {participant_id, message_id} =
          put_delivery!(group_id, conversation_id, participant_id, delivery)

        diagnostic =
          wake_delivery_and_wait!(
            group_id,
            conversation_id,
            participant_id,
            message_id,
            "unknown"
          )

        assert diagnostic["delivery"]["last_error"] =~ "missing_operation_ref"

        assert MockSlack.requests("chat.postMessage") == []
        assert MockSlack.requests("conversations.replies") == []

        assert diagnostic["delivery"]["delivery_result"] == %{
                 "status" => "delivery_missing_operation_ref"
               }
      end
    end

    test "stale provider delivery is marked unknown instead of resent", %{
      agent_id: agent_id,
      group_id: group_id,
      slack_connect_id: connect_id
    } do
      conversation_id = Ids.new_conversation_id()
      message_id = Ids.new_message_id()
      participant_id = Ids.new_participant_id()
      now = SystemsClock.system_time(:millisecond)

      seed_group_conversation(group_id, agent_id, %{"conversation_id" => conversation_id})

      delivery = %{
        "delivery_id" => "#{group_id}:#{conversation_id}:#{message_id}:#{participant_id}",
        "status" => "delivering",
        "delivery_started_at" => now - 180_000,
        "agent_group_id" => group_id,
        "conversation_id" => conversation_id,
        "message_id" => message_id,
        "participant_id" => participant_id,
        "participant_actor_type" => "provider",
        "participant_provider" => "slack",
        "participant_payload" => %{
          "connect_id" => connect_id,
          "channel_id" => "C-stale",
          "thread_ts" => "20.000"
        },
        "operation_ref" => "groupconv-delivery-stale-unknown",
        "message_content" => [%{"type" => "text", "text" => "do not resend stale"}],
        "message_created_at" => now
      }

      {participant_id, message_id} =
        put_delivery!(group_id, conversation_id, participant_id, delivery)

      MockSlack.respond("conversations.replies", %{"ok" => true, "messages" => []})

      diagnostic =
        wake_delivery_and_wait!(
          group_id,
          conversation_id,
          participant_id,
          message_id,
          "unknown"
        )

      assert diagnostic["delivery"]["last_error"] =~ "stale_provider_delivery_unverified"

      assert MockSlack.requests("chat.postMessage") == []
      assert [replies_req] = MockSlack.requests("conversations.replies")
      assert replies_req.params["channel"] == "C-stale"
      assert replies_req.params["ts"] == "20.000"

      assert diagnostic["delivery"]["delivery_result"] == %{
               "status" => "stale_provider_delivery_unverified"
             }
    end

    test "provider send success records unknown when delivered mark loses ownership", %{
      agent_id: agent_id,
      group_id: group_id,
      slack_connect_id: connect_id
    } do
      conversation_id = Ids.new_conversation_id()
      message_id = Ids.new_message_id()
      participant_id = Ids.new_participant_id()

      seed_group_conversation(group_id, agent_id, %{"conversation_id" => conversation_id})

      delivery = %{
        "delivery_id" => "#{group_id}:#{conversation_id}:#{message_id}:#{participant_id}",
        "status" => "pending",
        "agent_group_id" => group_id,
        "conversation_id" => conversation_id,
        "message_id" => message_id,
        "participant_id" => participant_id,
        "participant_actor_type" => "provider",
        "participant_provider" => "slack",
        "participant_payload" => %{
          "connect_id" => connect_id,
          "channel_id" => "C-unknown",
          "thread_ts" => "31.000"
        },
        "operation_ref" => "groupconv-delivery-mark-unknown",
        "message_content" => [%{"type" => "text", "text" => "sent but mark unknown"}],
        "message_created_at" => SystemsClock.system_time(:millisecond)
      }

      {participant_id, message_id} =
        put_delivery!(group_id, conversation_id, participant_id, delivery)

      key = delivery_key(group_id, conversation_id, message_id, participant_id)

      MockSlack.respond_with("chat.postMessage", fn _req ->
        {:ok, %{body: body, etag: etag}} = SalixStore.S3.get(key)

        body
        |> Jason.decode!()
        |> Map.put("test_owner_touched", true)
        |> Jason.encode!()
        |> then(&SalixStore.S3.put(key, &1, if_match: etag))

        %{"ok" => true, "channel" => "C-unknown", "ts" => "31.123"}
      end)

      diagnostic =
        wake_delivery_and_wait!(
          group_id,
          conversation_id,
          participant_id,
          message_id,
          "unknown"
        )

      assert diagnostic["delivery"]["last_error"] =~ "ownership_lost"

      assert [_request] = MockSlack.requests("chat.postMessage")

      assert diagnostic["delivery"]["delivery_result"] == %{
               "side_effect_result" => %{"channel" => "C-unknown", "ts" => "31.123"},
               "status" => "delivery_acknowledgement_unknown"
             }
    end

    test "a signed checkbox action persists the selected state on the exact Slack message" do
      assert {:ok, %{text: fallback, blocks: blocks}} =
               SalixIM.Provider.Slack.MessageRenderer.render(
                 "Checklist\n\n- [ ] Add regression coverage\n- [x] Keep the fallback"
               )

      actions = Enum.find(blocks, &(&1["type"] == "actions"))
      checkbox = get_in(actions, ["elements", Access.at(0)])
      [first, _second] = checkbox["options"]

      payload = %{
        "type" => "block_actions",
        "api_app_id" => "A1",
        "team" => %{"id" => "T1"},
        "channel" => %{"id" => "C9"},
        "container" => %{
          "type" => "message",
          "channel_id" => "C9",
          "message_ts" => "1.2"
        },
        "message" => %{
          "text" => fallback,
          "ts" => "1.2",
          "blocks" => blocks
        },
        "actions" => [
          %{
            "type" => "checkboxes",
            "block_id" => actions["block_id"],
            "action_id" => checkbox["action_id"],
            "selected_options" => [first]
          }
        ]
      }

      raw_body = "payload=" <> URI.encode_www_form(Jason.encode!(payload))
      headers = sign_slack_body(raw_body, "task-card-signing-secret")
      MockSlack.respond("chat.update", %{"ok" => true, "channel" => "C9", "ts" => "1.2"})

      assert {:ok, :accepted} =
               SalixIM.ProviderHTTP.handle_slack_interaction(
                 "A1",
                 payload,
                 headers,
                 raw_body
               )

      update = MockSlack.last_request("chat.update")
      assert update.params["channel"] == "C9"
      assert update.params["ts"] == "1.2"
      assert update.params["text"] == fallback

      updated_blocks = Jason.decode!(update.params["blocks"])
      updated_actions = Enum.find(updated_blocks, &(&1["type"] == "actions"))
      updated_checkbox = get_in(updated_actions, ["elements", Access.at(0)])
      assert updated_checkbox["initial_options"] == [first]

      assert {:error, :invalid_signature} =
               SalixIM.ProviderHTTP.handle_slack_interaction(
                 "A1",
                 payload,
                 [{"x-slack-request-timestamp", "1"}, {"x-slack-signature", "v0=bad"}],
                 raw_body
               )

      assert length(MockSlack.requests("chat.update")) == 1
    end

    test "a declassification request reaches the requester as a card only they can act on", %{
      group_id: group_id,
      tenant: tenant,
      slack_connect_id: connect_id
    } do
      MockSlack.respond("conversations.open", %{"ok" => true, "channel" => %{"id" => "D9"}})
      MockSlack.respond("chat.postMessage", %{"ok" => true, "channel" => "D9", "ts" => "9.1"})

      assert :ok =
               SalixIM.IFC.SlackConfirmation.post(%{
                 "request_id" => "req_ifc_card",
                 "group_id" => group_id,
                 "tenant_id" => tenant,
                 "request_type" => "ifc_declassify",
                 "status" => "pending",
                 "request_payload" => %{
                   "ifc_declassify" => %{
                     "requester" => "provider_user|#{connect_id}|U_A",
                     "source_atoms" => ["scope|#{connect_id}|@U_A"],
                     "destination_atoms" => ["scope|#{connect_id}|C_TEAM"],
                     "source_names" => ["私聊"],
                     "destination_names" => ["#team"],
                     "summary" => "把你私聊里的交接清单发到 #team"
                   }
                 }
               })

      # Asked in that person's own conversation with the bot, and nowhere else.
      assert MockSlack.last_request("conversations.open").params["users"] == "U_A"

      posted = MockSlack.last_request("chat.postMessage")
      assert posted.params["channel"] == "D9"

      blocks = Jason.decode!(posted.params["blocks"])
      rendered = Jason.encode!(blocks)

      # The card names the flow and carries the buttons that decide it.
      assert rendered =~ "ifc_declassify:approve"
      assert rendered =~ "ifc_declassify:deny"
      assert rendered =~ "req_ifc_card"
      assert rendered =~ "私聊"
      assert rendered =~ "#team"
      assert rendered =~ "把你私聊里的交接清单发到 #team"
    end

    test "a signed declassification button is answered only by the person it was asked of", %{
      group_id: group_id,
      tenant: tenant,
      slack_connect_id: connect_id
    } do
      request = %{
        "request_id" => "req_ifc_1",
        "group_id" => group_id,
        "tenant_id" => tenant,
        "request_type" => "ifc_declassify",
        "status" => "pending",
        "request_payload" => %{
          "ifc_declassify" => %{
            "capability" => "ifc_declassify",
            "requester" => "provider_user|#{connect_id}|U_A",
            "source_atoms" => ["scope|#{connect_id}|@U_A"],
            "destination_atoms" => ["scope|#{connect_id}|C_TEAM"],
            "source_names" => ["私聊"],
            "destination_names" => ["#team"],
            "summary" => "把你私聊里的交接清单发到 #team"
          }
        }
      }

      SalixIM.Test.IFCCapabilityRequestsStub.install(request)
      on_exit(&SalixIM.Test.IFCCapabilityRequestsStub.uninstall/0)

      payload = fn user_id ->
        %{
          "type" => "block_actions",
          "api_app_id" => "A1",
          "team" => %{"id" => "T1"},
          "channel" => %{"id" => "D1"},
          "user" => %{"id" => user_id},
          "message" => %{"ts" => "1.3", "text" => "确认转发"},
          "actions" => [
            %{
              "type" => "button",
              "action_id" => "ifc_declassify:approve",
              "value" => "req_ifc_1"
            }
          ]
        }
      end

      # Someone else pressing the button decides nothing. The card is a
      # question for one person, and a forwarded or replayed payload is not
      # that person.
      foreign = payload.("U_B")
      foreign_body = "payload=" <> URI.encode_www_form(Jason.encode!(foreign))

      assert {:error, {:ignored, :ifc_declassify_wrong_user}} =
               SalixIM.ProviderHTTP.handle_slack_interaction(
                 "A1",
                 foreign,
                 sign_slack_body(foreign_body, "task-card-signing-secret"),
                 foreign_body
               )

      refute_received {:ifc_stub_decided, _group, _request, _attrs, _tenant}

      # An unsigned press never reaches the handler at all.
      own = payload.("U_A")
      own_body = "payload=" <> URI.encode_www_form(Jason.encode!(own))

      assert {:error, :invalid_signature} =
               SalixIM.ProviderHTTP.handle_slack_interaction(
                 "A1",
                 own,
                 [{"x-slack-request-timestamp", "1"}, {"x-slack-signature", "v0=bad"}],
                 own_body
               )

      refute_received {:ifc_stub_decided, _group, _request, _attrs, _tenant}

      MockSlack.respond("chat.update", %{"ok" => true, "channel" => "D1", "ts" => "1.3"})

      assert {:ok, :accepted} =
               SalixIM.ProviderHTTP.handle_slack_interaction(
                 "A1",
                 own,
                 sign_slack_body(own_body, "task-card-signing-secret"),
                 own_body
               )

      assert_received {:ifc_stub_decided, ^group_id, "req_ifc_1", %{"approved" => true}, ^tenant}

      # The card is replaced by what was decided, so it cannot be pressed
      # twice from a message left in the conversation.
      update = MockSlack.last_request("chat.update")
      assert update.params["channel"] == "D1"
      assert update.params["ts"] == "1.3"
      assert update.params["text"] =~ "已确认转发"
      refute Jason.decode!(update.params["blocks"]) |> Jason.encode!() =~ "ifc_declassify:approve"
    end

    test "dynamic Slack message APIs reject every model-owned Block Kit payload", %{
      agent_id: agent_id,
      slack_connect_id: connect_id
    } do
      section = %{
        "type" => "section",
        "text" => %{"type" => "mrkdwn", "text" => "*hello*"}
      }

      assert {:error, "render_mode and blocks are not supported; send standard Markdown text"} =
               call(agent_id, "slack", "slack.post_message", connect_id, %{
                 "channel" => "C9",
                 "text" => "hello",
                 "render_mode" => "mrkdwn",
                 "blocks" => [section]
               })

      assert {:error, "render_mode and blocks are not supported; send standard Markdown text"} =
               call(agent_id, "slack", "slack.update_message", connect_id, %{
                 "channel" => "C9",
                 "ts" => "1.2",
                 "text" => "hello",
                 "render_mode" => "blocks",
                 "blocks" => [Map.put(section, "accessory", %{"type" => "icon_button"})]
               })

      assert {:error, "render_mode and blocks are not supported; send standard Markdown text"} =
               call(agent_id, "slack", "slack.send_dm", connect_id, %{
                 "user_id" => "U1",
                 "text" => "hello",
                 "render_mode" => "blocks",
                 "blocks" => [Map.put(section, "accessory", %{"type" => "feedback_buttons"})]
               })

      assert MockSlack.requests("chat.postMessage") == []
      assert MockSlack.requests("chat.update") == []
      assert MockSlack.requests("conversations.open") == []
    end

    test "slack.send_dm opens the conversation then posts", %{
      agent_id: agent_id,
      slack_connect_id: connect_id
    } do
      MockSlack.respond("conversations.open", %{"ok" => true, "channel" => %{"id" => "D7"}})
      MockSlack.respond("chat.postMessage", %{"ok" => true, "channel" => "D7", "ts" => "9.9"})

      assert {:ok, %{"channel" => "D7", "ts" => "9.9"}} =
               call(agent_id, "slack", "slack.send_dm", connect_id, %{
                 "user_id" => "U1",
                 "text" => "hi"
               })

      open_req = MockSlack.last_request("conversations.open")
      assert open_req.content_type =~ "application/x-www-form-urlencoded"
      assert open_req.params["users"] == "U1"

      post_req = MockSlack.last_request("chat.postMessage")
      assert post_req.content_type =~ "application/x-www-form-urlencoded"
      assert post_req.params["channel"] == "D7"
    end

    test "slack.list_channels defaults and projection", %{
      agent_id: agent_id,
      slack_connect_id: connect_id
    } do
      MockSlack.respond("conversations.list", %{
        "ok" => true,
        "channels" => [
          %{"id" => "C1", "name" => "general"},
          %{"id" => "C2", "name" => "secret", "is_private" => true, "is_archived" => true}
        ],
        "response_metadata" => %{"next_cursor" => "CCUR"}
      })

      assert {:ok, %{"channels" => channels, "next_cursor" => "CCUR"}} =
               call(agent_id, "slack", "slack.list_channels", connect_id, %{"cursor" => "CUR"})

      assert channels == [
               %{"id" => "C1", "name" => "general"},
               %{"id" => "C2", "name" => "secret", "is_private" => true, "is_archived" => true}
             ]

      req = MockSlack.last_request("conversations.list")
      assert req.content_type =~ "application/x-www-form-urlencoded"
      assert req.params["limit"] == "100"
      assert req.params["cursor"] == "CUR"
      assert req.params["types"] == "public_channel,private_channel"
      assert req.params["exclude_archived"] == "true"
    end

    test "slack.list_users defaults, filters deleted users, and returns pagination", %{
      agent_id: agent_id,
      slack_connect_id: connect_id
    } do
      MockSlack.respond("users.list", %{
        "ok" => true,
        "members" => [
          %{
            "id" => "U1",
            "name" => "jdoe",
            "real_name" => "Jane Doe",
            "is_bot" => false,
            "profile" => %{
              "display_name" => "jane",
              "email" => "jane@example.com",
              "title" => "Eng"
            }
          },
          %{
            "id" => "U2",
            "name" => "inactive",
            "real_name" => "Inactive User",
            "deleted" => true,
            "is_bot" => false
          }
        ],
        "response_metadata" => %{"next_cursor" => "NEXT"}
      })

      assert {:ok, %{"users" => users, "next_cursor" => "NEXT"}} =
               call(agent_id, "slack", "slack.list_users", connect_id, %{})

      assert users == [
               %{
                 "id" => "U1",
                 "name" => "jdoe",
                 "real_name" => "Jane Doe",
                 "is_bot" => false,
                 "display_name" => "jane",
                 "email" => "jane@example.com",
                 "title" => "Eng"
               }
             ]

      req = MockSlack.last_request("users.list")
      assert req.content_type =~ "application/x-www-form-urlencoded"
      assert req.params["limit"] == "100"
      refute Map.has_key?(req.params, "cursor")
      refute Map.has_key?(req.params, "include_deleted")
      refute Map.has_key?(req.params, "query")
    end

    test "slack.create_channel creates a normalized public or private channel and returns a compact summary",
         %{
           agent_id: agent_id,
           slack_connect_id: connect_id
         } do
      MockSlack.respond("conversations.create", %{
        "ok" => true,
        "channel" => %{
          "id" => "C77",
          "name" => "launch-room",
          "is_channel" => true,
          "is_private" => false,
          "creator" => "UBOT",
          "topic" => %{"value" => "large provider field omitted"}
        }
      })

      assert {:ok, %{"channel" => "C77", "name" => "launch-room", "is_private" => false}} =
               call(agent_id, "slack", "slack.create_channel", connect_id, %{
                 "name" => "#Launch-Room"
               })

      req = MockSlack.last_request("conversations.create")
      assert req.content_type =~ "application/x-www-form-urlencoded"
      assert req.params == %{"name" => "launch-room", "is_private" => "false"}

      MockSlack.respond("conversations.create", %{
        "ok" => true,
        "channel" => %{"id" => "G88", "name" => "exec-only", "is_private" => true}
      })

      assert {:ok, %{"channel" => "G88", "name" => "exec-only", "is_private" => true}} =
               call(agent_id, "slack", "slack.create_channel", connect_id, %{
                 "name" => "exec-only",
                 "is_private" => true
               })

      assert MockSlack.last_request("conversations.create").params["is_private"] == "true"
      created_before_invalid = length(MockSlack.requests("conversations.create"))

      assert {:error, "name required"} =
               call(agent_id, "slack", "slack.create_channel", connect_id, %{})

      assert {:error, reason} =
               call(agent_id, "slack", "slack.create_channel", connect_id, %{
                 "name" => "launch room"
               })

      assert reason =~ "lowercase letters, numbers, hyphens, and underscores"

      assert {:error, reason} =
               call(agent_id, "slack", "slack.create_channel", connect_id, %{
                 "name" => String.duplicate("a", 81)
               })

      assert reason =~ "at most 80 characters"
      # Locally rejected names never reach Slack.
      assert length(MockSlack.requests("conversations.create")) == created_before_invalid

      MockSlack.respond("conversations.create", %{"ok" => false, "error" => "name_taken"})

      assert {:error, "Slack API error: name_taken"} =
               call(agent_id, "slack", "slack.create_channel", connect_id, %{
                 "name" => "launch-room"
               })
    end

    test "slack.update_message deliveries chat.update with rendered text", %{
      agent_id: agent_id,
      slack_connect_id: connect_id
    } do
      MockSlack.respond("chat.update", %{"ok" => true, "channel" => "C9", "ts" => "1.2"})

      assert {:ok, %{"channel" => "C9", "ts" => "1.2"}} =
               call(agent_id, "slack", "slack.update_message", connect_id, %{
                 "channel" => "C9",
                 "ts" => "1.2",
                 "text" => "updated **88%**；"
               })

      req = MockSlack.last_request("chat.update")
      assert req.params["channel"] == "C9"
      assert req.params["ts"] == "1.2"
      assert req.params["text"] == "updated **88%**；"

      assert [%{"type" => "rich_text", "elements" => [%{"elements" => prose}]}] =
               Jason.decode!(req.params["blocks"])

      assert prose == [
               %{"type" => "text", "text" => "updated "},
               %{"type" => "text", "text" => "88%", "style" => %{"bold" => true}},
               %{"type" => "text", "text" => "；"}
             ]
    end

    test "slack write operations delivery to the expected Slack Web API form methods", %{
      agent_id: agent_id,
      slack_connect_id: connect_id
    } do
      cases = [
        {"slack.delete_message", "chat.delete", %{"channel" => "C9", "ts" => "1.2"},
         %{"channel" => "C9", "ts" => "1.2"}, %{"channel" => "C9", "ts" => "1.2"}},
        {"slack.add_reaction", "reactions.add",
         %{"channel" => "C9", "ts" => "1.2", "name" => ":white_check_mark:"},
         %{"channel" => "C9", "timestamp" => "1.2", "name" => "white_check_mark"},
         %{"ok" => true}},
        {"slack.pin_message", "pins.add", %{"channel" => "C9", "ts" => "1.2"},
         %{"channel" => "C9", "timestamp" => "1.2"}, %{"ok" => true}},
        {"slack.unpin_message", "pins.remove", %{"channel" => "C9", "ts" => "1.2"},
         %{"channel" => "C9", "timestamp" => "1.2"}, %{"ok" => true}},
        {"slack.set_channel_topic", "conversations.setTopic",
         %{"channel" => "C9", "topic" => "Launch room"},
         %{"channel" => "C9", "topic" => "Launch room"}, %{"topic" => "Launch room"}},
        {"slack.set_channel_purpose", "conversations.setPurpose",
         %{"channel" => "C9", "purpose" => "Ship launch updates"},
         %{"channel" => "C9", "purpose" => "Ship launch updates"},
         %{"purpose" => "Ship launch updates"}},
        {"slack.invite_users", "conversations.invite",
         %{"channel" => "C9", "users" => ["U1", "U2"]}, %{"channel" => "C9", "users" => "U1,U2"},
         %{"channel" => "C9"}},
        {"slack.add_bookmark", "bookmarks.add",
         %{"channel" => "C9", "title" => "Runbook", "url" => "https://example.com/runbook"},
         %{
           "channel_id" => "C9",
           "title" => "Runbook",
           "type" => "link",
           "link" => "https://example.com/runbook"
         }, %{"bookmark" => %{"id" => "Bk1"}}}
      ]

      for {api, method, params, expected_form, success_result} <- cases do
        MockSlack.respond(method, Map.put(success_result, "ok", true))

        assert {:ok, ^success_result} = call(agent_id, "slack", api, connect_id, params)

        req = MockSlack.last_request(method)
        assert req.content_type =~ "application/x-www-form-urlencoded"

        for {key, value} <- expected_form do
          assert req.params[key] == value
        end
      end
    end

    test "slack read operations return compact paginated projections", %{
      agent_id: agent_id,
      slack_connect_id: connect_id
    } do
      MockSlack.respond("conversations.members", %{
        "ok" => true,
        "members" => ["U1", "U2"],
        "response_metadata" => %{"next_cursor" => "MCUR"}
      })

      assert {:ok, %{"members" => ["U1", "U2"], "next_cursor" => "MCUR"}} =
               call(agent_id, "slack", "slack.list_channel_members", connect_id, %{
                 "channel" => "C9",
                 "limit" => 500,
                 "cursor" => "CUR"
               })

      members_req = MockSlack.last_request("conversations.members")
      assert members_req.params["channel"] == "C9"
      assert members_req.params["limit"] == "200"
      assert members_req.params["cursor"] == "CUR"

      MockSlack.respond("conversations.replies", %{
        "ok" => true,
        "messages" => [
          %{"type" => "message", "user" => "U1", "text" => "parent", "ts" => "1.0"},
          %{"type" => "message", "user" => "U2", "text" => "reply", "ts" => "1.1"}
        ],
        "response_metadata" => %{"next_cursor" => "RCUR"}
      })

      assert {:ok, %{"messages" => replies, "next_cursor" => "RCUR"}} =
               call(agent_id, "slack", "slack.get_thread_replies", connect_id, %{
                 "channel" => "C9",
                 "ts" => "1.0"
               })

      assert Enum.map(replies, &Map.take(&1, ["user", "text", "ts"])) == [
               %{"user" => "U1", "text" => "parent", "ts" => "1.0"},
               %{"user" => "U2", "text" => "reply", "ts" => "1.1"}
             ]

      replies_req = MockSlack.last_request("conversations.replies")
      assert replies_req.params["channel"] == "C9"
      assert replies_req.params["ts"] == "1.0"
      assert replies_req.params["limit"] == "100"

      MockSlack.respond("conversations.history", %{
        "ok" => true,
        "messages" => [%{"type" => "message", "user" => "U1", "text" => "latest", "ts" => "2.0"}],
        "response_metadata" => %{"next_cursor" => "HCUR"}
      })

      assert {:ok, %{"messages" => [%{"text" => "latest"}], "next_cursor" => "HCUR"}} =
               call(agent_id, "slack", "slack.get_channel_history", connect_id, %{
                 "channel" => "C9",
                 "oldest" => "1.0",
                 "latest" => "3.0",
                 "inclusive" => true
               })

      history_req = MockSlack.last_request("conversations.history")
      assert history_req.params["channel"] == "C9"
      assert history_req.params["oldest"] == "1.0"
      assert history_req.params["latest"] == "3.0"
      assert history_req.params["inclusive"] == "true"
    end

    test "slack.get_thread_replies reads the first chronological page before a message", %{
      agent_id: agent_id,
      slack_connect_id: connect_id
    } do
      MockSlack.respond("conversations.replies", %{
        "ok" => true,
        "messages" => [
          %{"type" => "message", "user" => "U-root", "text" => "root", "ts" => "1.0"},
          %{"type" => "message", "user" => "U2", "text" => "first reply", "ts" => "1.2"},
          %{"type" => "message", "user" => "U3", "text" => "second reply", "ts" => "1.3"}
        ],
        "has_more" => true,
        "response_metadata" => %{"next_cursor" => "OLDER-CURSOR"}
      })

      assert {:ok,
              %{
                "messages" => messages,
                "has_more" => true,
                "next_cursor" => "OLDER-CURSOR"
              }} =
               call(agent_id, "slack", "slack.get_thread_replies", connect_id, %{
                 "channel" => "C9",
                 "ts" => "1.0",
                 "before_ts" => "1.5",
                 "limit" => 3
               })

      assert Enum.map(messages, & &1["ts"]) == ["1.0", "1.2", "1.3"]

      request = MockSlack.last_request("conversations.replies")
      assert request.params["channel"] == "C9"
      assert request.params["ts"] == "1.0"
      assert request.params["latest"] == "1.5"
      assert request.params["inclusive"] == "false"
      assert request.params["limit"] == "3"
      refute Map.has_key?(request.params, "before_ts")
    end

    test "a later tool call uses the rotated token and its own Slack response", %{
      agent_id: agent_id,
      group_id: group_id,
      slack_connect_id: connect_id
    } do
      configure_slack_tool_retry(budget_ms: 0, max_retries: 0)

      MockSlack.respond("conversations.history", 429, [{"retry-after", "30"}], %{
        "ok" => false,
        "error" => "ratelimited"
      })

      assert {:error, _rate_limited} =
               call(agent_id, "slack", "slack.get_channel_history", connect_id, %{
                 "channel" => "C-token-rotation-budget"
               })

      assert {:ok, connect} =
               SalixIM.ProviderConnects.get_active_connect_by_id(group_id, connect_id, "slack")

      assert {:ok, _public_connect} =
               SalixIM.ProviderConnects.complete_slack_im_connect_oauth(connect, %{
                 "bot_token" => "xoxb-rotated",
                 "bot_id" => "B1",
                 "bot_user_id" => "U-BOT",
                 "workspace_id" => "T1",
                 "workspace_name" => "Acme",
                 "enterprise_id" => nil,
                 "owner_user_id" => "U-OWNER"
               })

      MockSlack.respond("conversations.history", %{"ok" => true, "messages" => []})

      assert {:ok, %{"messages" => []}} =
               call(agent_id, "slack", "slack.get_channel_history", connect_id, %{
                 "channel" => "C-token-rotation-budget"
               })

      assert Enum.map(MockSlack.requests("conversations.history"), & &1.auth) == [
               "Bearer xoxb-test",
               "Bearer xoxb-rotated"
             ]
    end

    test "slack.fetch_file downloads a file by id into the agent VFS on demand", %{
      agent_id: agent_id,
      slack_connect_id: connect_id
    } do
      # The agent runtime must exist for VFS staging (in production the agent is
      # running when it calls the tool); seed it so Control.get/put_ref resolve.
      seed_agent_vfs(agent_id, %{})

      api_base = SystemsRuntime.get_env(:salix_im, :slack_api_base_url)
      download_base = String.replace_suffix(api_base, "/api", "")
      MockSlack.respond("canvas_download", @png)

      MockSlack.respond("files.info", %{
        "ok" => true,
        "file" => %{
          "id" => "F100",
          "name" => "diagram.png",
          "mimetype" => "image/png",
          "size" => byte_size(@png),
          "url_private_download" => "#{download_base}/files/F100"
        }
      })

      assert {:ok, %{"vfs_path" => path, "name" => "diagram.png", "mimetype" => "image/png"}} =
               call(agent_id, "slack", "slack.fetch_file", connect_id, %{"file_id" => "F100"})

      assert path == SalixIM.SlackFiles.file_vfs_path(%{"id" => "F100", "name" => "diagram.png"})

      info_req = MockSlack.last_request("files.info")
      assert info_req.params["file"] == "F100"

      # The bytes were actually staged into the agent VFS.
      assert {:ok, %{data: @png}} =
               SalixIM.Ports.AgentWorkspace.read_upload(agent_id, path)
    end

    test "slack.upload_file refuses host filesystem paths", %{
      agent_id: agent_id,
      slack_connect_id: connect_id
    } do
      seed_agent_vfs(agent_id, %{})
      host_path = host_file!("HOST-SECRET-SLACK")

      assert {:error, message} =
               call(agent_id, "slack", "slack.upload_file", connect_id, %{
                 "path" => host_path,
                 "channel" => "C9"
               })

      assert message =~ "file not found in agent VFS"
      assert MockSlack.requests("files.getUploadURLExternal") == []
    end

    test "slack.upload_file uses external upload flow with bytes from agent VFS", %{
      agent_id: agent_id,
      group_id: group_id,
      slack_connect_id: connect_id
    } do
      seed_agent_vfs(agent_id, %{"/attachments/report.pdf" => "PDF-VFS-BYTES"})

      base =
        :salix_im
        |> SystemsRuntime.fetch_env!(:slack_api_base_url)
        |> String.replace_suffix("/api", "")

      MockSlack.respond("files.getUploadURLExternal", %{
        "ok" => true,
        "upload_url" => base <> "/upload/F1",
        "file_id" => "F1"
      })

      MockSlack.respond("files.completeUploadExternal", %{
        "ok" => true,
        "files" => [%{"id" => "F1", "name" => "report.pdf"}]
      })

      assert {:ok, %{"files" => [%{"id" => "F1", "name" => "report.pdf"}]}} =
               call(agent_id, "slack", "slack.upload_file", connect_id, %{
                 "path" => "/attachments/report.pdf",
                 "channel" => "C9",
                 "thread_ts" => "1.0",
                 "initial_comment" =>
                   "<@U0AU3GAP8ER> 检查完了。\n\n**PDF**：中文可读。\n\n" <>
                     "**Report** [details](https://example.test/report)\n\n" <>
                     "~~a~b~~ and **a~b~c**\n\n- Ready",
                 "title" => "Q3 report"
               })

      upload_url_req = MockSlack.last_request("files.getUploadURLExternal")
      assert upload_url_req.params["filename"] == "report.pdf"
      assert upload_url_req.params["length"] == "13"

      [upload_req] = MockSlack.requests("external_upload")
      assert upload_req.raw == "PDF-VFS-BYTES"
      assert upload_req.content_type == "application/octet-stream"

      complete_req = MockSlack.last_request("files.completeUploadExternal")

      assert Jason.decode!(complete_req.params["files"]) == [
               %{"id" => "F1", "title" => "Q3 report"}
             ]

      assert complete_req.params["channel_id"] == "C9"
      assert complete_req.params["thread_ts"] == "1.0"
      refute Map.has_key?(complete_req.params, "initial_comment")
      [mention, prose | _rest] = Jason.decode!(complete_req.params["blocks"])
      assert mention["type"] == "section"
      assert mention["text"]["type"] == "mrkdwn"
      assert mention["text"]["text"] == "<@U0AU3GAP8ER> 检查完了。"

      assert prose == %{
               "type" => "rich_text",
               "elements" => [
                 %{
                   "type" => "rich_text_section",
                   "elements" => [
                     %{"type" => "text", "text" => "PDF", "style" => %{"bold" => true}},
                     %{"type" => "text", "text" => "：中文可读。"}
                   ]
                 }
               ]
             }

      assert SalixStore.SlackRouterThreadParticipations.participating?(
               group_id,
               connect_id,
               "T1",
               "Ubot",
               "C9",
               "1.0"
             )
    end

    test "slack.create_canvas creates a standalone canvas from markdown", %{
      agent_id: agent_id,
      slack_connect_id: connect_id
    } do
      MockSlack.respond("canvases.create", %{"ok" => true, "canvas_id" => "F_CAN1"})

      assert {:ok, %{"canvas_id" => "F_CAN1"}} =
               call(agent_id, "slack", "slack.create_canvas", connect_id, %{
                 "title" => "Runbook",
                 "content" => "# Runbook\nSteps"
               })

      req = MockSlack.last_request("canvases.create")
      assert req.params["title"] == "Runbook"

      assert Jason.decode!(req.params["document_content"]) == %{
               "type" => "markdown",
               "markdown" => "# Runbook\nSteps"
             }

      assert MockSlack.requests("conversations.canvases.create") == []
    end

    test "slack.edit_canvas replaces the whole document by default", %{
      agent_id: agent_id,
      slack_connect_id: connect_id
    } do
      MockSlack.respond("canvases.edit", %{"ok" => true})

      assert {:ok, %{"canvas_id" => "F_CAN1"}} =
               call(agent_id, "slack", "slack.edit_canvas", connect_id, %{
                 "canvas_id" => "F_CAN1",
                 "content" => "# New"
               })

      req = MockSlack.last_request("canvases.edit")
      assert req.params["canvas_id"] == "F_CAN1"

      assert Jason.decode!(req.params["changes"]) == [
               %{
                 "operation" => "replace",
                 "document_content" => %{"type" => "markdown", "markdown" => "# New"}
               }
             ]
    end

    test "slack.fetch_canvas identifies Slack's provider-rendered HTML", %{
      agent_id: agent_id,
      slack_connect_id: connect_id
    } do
      base =
        :salix_im
        |> SystemsRuntime.fetch_env!(:slack_api_base_url)
        |> String.replace_suffix("/api", "")

      MockSlack.respond("files.info", %{
        "ok" => true,
        "file" => %{
          "id" => "F_CAN1",
          "title" => "Runbook",
          "url_private_download" => base <> "/files/F_CAN1"
        }
      })

      MockSlack.respond(
        "canvas_download",
        ~s(<div class="quip-canvas-content"><h1>Runbook</h1><p>Downloaded body</p></div>)
      )

      assert {:ok, result} =
               call(agent_id, "slack", "slack.fetch_canvas", connect_id, %{
                 "canvas_id" => "F_CAN1"
               })

      assert result["canvas_id"] == "F_CAN1"
      assert result["title"] == "Runbook"
      assert result["content"] =~ ~s(class="quip-canvas-content")
      assert result["content_format"] == "provider_rendered_html"
      assert result["markdown"] == result["content"]

      download_req = MockSlack.last_request("canvas_download")
      assert download_req.auth =~ "Bearer "
    end

    test "workers reach router-bound Slack connects for granted operations only",
         %{tenant: tenant, group_id: group_id, slack_connect_id: connect_id} do
      {:ok, worker} =
        create_control_agent(
          %{"name" => "Worker", "group_id" => group_id, "role" => "worker"},
          tenant
        )

      {:ok, other_worker} =
        create_control_agent(
          %{"name" => "Other Worker", "group_id" => group_id, "role" => "worker"},
          tenant
        )

      seed_connect(group_id, "sl-other-worker-call", "slack", %{
        "tenant_id" => tenant,
        "workspace_id" => "T-other-worker",
        "workspace_name" => "Other Worker Slack",
        "bot_token" => "xoxb-test",
        "oauth_completed_at" => 1,
        "inbound_agent_id" => other_worker["agent_id"]
      })

      MockSlack.respond("conversations.list", %{
        "ok" => true,
        "channels" => [%{"id" => "C1", "name" => "general"}]
      })

      assert {:ok, %{"channels" => [%{"id" => "C1"}]}} =
               call(worker["agent_id"], "slack", "slack.list_channels", connect_id, %{})

      # A linked thread in another channel uses the Router's same read surface.
      MockSlack.respond("conversations.replies", %{
        "ok" => true,
        "messages" => [
          %{"ts" => "1789607441.811059", "text" => "Original incident"},
          %{"ts" => "1789609004.330029", "text" => "Diagnosis remains unverified"}
        ],
        "has_more" => false
      })

      params = %{"channel" => "C-linked", "ts" => "1789607441.811059", "limit" => 20}
      {:ok, group} = SalixIM.GroupDirectory.get_group(group_id)

      assert {:ok, router_page} =
               call(
                 group["router_agent_id"],
                 "slack",
                 "slack.get_thread_replies",
                 connect_id,
                 params
               )

      assert {:ok, worker_page} =
               call(worker["agent_id"], "slack", "slack.get_thread_replies", connect_id, params)

      assert worker_page["messages"] == router_page["messages"]

      assert Enum.map(worker_page["messages"], & &1["text"]) ==
               ["Original incident", "Diagnosis remains unverified"]

      assert {:error, "operation is not available to this agent role"} =
               call(worker["agent_id"], "slack", "slack.post_message", connect_id, %{
                 "channel" => "C9",
                 "text" => "x"
               })

      # fetch_file is the one granted media download: it stages Slack bytes
      # into the worker VFS without mutating Slack.
      seed_agent_vfs(worker["agent_id"], %{})

      api_base = SystemsRuntime.get_env(:salix_im, :slack_api_base_url)
      download_base = String.replace_suffix(api_base, "/api", "")
      MockSlack.respond("canvas_download", @png)

      MockSlack.respond("files.info", %{
        "ok" => true,
        "file" => %{
          "id" => "F100",
          "name" => "diagram.png",
          "mimetype" => "image/png",
          "size" => byte_size(@png),
          "url_private_download" => "#{download_base}/files/F100"
        }
      })

      assert {:ok, %{"vfs_path" => _, "name" => "diagram.png", "mimetype" => "image/png"}} =
               call(worker["agent_id"], "slack", "slack.fetch_file", connect_id, %{
                 "file_id" => "F100"
               })

      # upload_file is also media but mutates Slack, so it stays router-only.
      assert {:error, "operation is not available to this agent role"} =
               call(worker["agent_id"], "slack", "slack.upload_file", connect_id, %{
                 "path" => "/diagram.png"
               })

      # Worker-bound connects stay ingress-only and tool-invisible.
      assert {:error, "connect not found"} =
               call(
                 worker["agent_id"],
                 "slack",
                 "slack.list_channels",
                 "sl-other-worker-call",
                 %{}
               )

      assert {:error, "connect not found"} =
               call(worker["agent_id"], "slack", "slack.post_message", "sl-other-worker-call", %{
                 "channel" => "C9",
                 "text" => "x"
               })
    end

    test "Slack HTTP errors do not surface raw response secrets or message text", %{
      agent_id: agent_id,
      slack_connect_id: connect_id
    } do
      MockSlack.respond("chat.postMessage", 500, %{
        "ok" => false,
        "error" => "server_error",
        "token" => "xoxb-leaked",
        "text" => "private message body"
      })

      assert {:error, message} =
               call(agent_id, "slack", "slack.post_message", connect_id, %{
                 "channel" => "C9",
                 "text" => "private message body"
               })

      assert message == "Slack HTTP 500"
      refute message =~ "xoxb"
      refute message =~ "private message body"
      refute message =~ "server_error"
      assert length(MockSlack.requests("chat.postMessage")) == 1
    end
  end

  describe "Comma-managed Telegram direct messages" do
    setup %{tenant: tenant, group_id: group_id} do
      SalixIM.Provider.Feishu.API.reset_token_cache()
      start_supervised!(MockProviderRuntime)
      base_url = BanditServer.serve!(MockProviderRuntime)
      prev = SystemsRuntime.get_env(:salix_im, :telegram_api_base_url)
      SystemsRuntime.put_env(:salix_im, :telegram_api_base_url, "#{base_url}")
      on_exit(fn -> restore(:salix_im, :telegram_api_base_url, prev) end)

      assert {:ok, connect} =
               SalixIM.ProviderConnects.ensure_managed_telegram_im_connect(
                 tenant,
                 group_id,
                 %{"bot_token" => "comma-managed-token", "telegram_user_id" => "42001"}
               )

      # This provider-level suite exercises already-published bindings. The
      # Comma API integration suite owns commit-before-activation coverage.
      :ok =
        SalixIM.ProviderConnects.activate_managed_telegram_im_connect(
          tenant,
          group_id,
          connect["connect_id"]
        )

      %{telegram_connect_id: connect["connect_id"]}
    end

    test "only permits the linked private peer and a narrow outbound API set", %{
      agent_id: agent_id,
      telegram_connect_id: connect_id
    } do
      assert {:error, "Telegram chat_id is outside this Comma-managed direct message"} =
               call(agent_id, "telegram", "telegram.send_message", connect_id, %{
                 "chat_id" => "99999",
                 "text" => "must not leak"
               })

      assert {:error, "unsupported Telegram API for a Comma-managed direct message"} =
               call(agent_id, "telegram", "telegram.list_users", connect_id, %{})

      assert {:ok, %{"message_id" => 78}} =
               call(agent_id, "telegram", "telegram.send_message", connect_id, %{
                 "chat_id" => "42001",
                 "text" => "private reply"
               })

      [request] = MockProviderRuntime.requests(:telegram_api)
      assert request.params["chat_id"] == "42001"
      assert request.params["text"] == "private reply"
      assert request.params["parse_mode"] == "HTML"
      refute Map.has_key?(request.params, "rich_message")
    end

    test "Home shows only sends that answer the linked chat, not copies of Home replies", %{
      agent_id: agent_id,
      group_id: group_id,
      telegram_connect_id: connect_id
    } do
      send = fn id, text, origin ->
        assert {:ok, _} =
                 call(
                   agent_id,
                   "telegram",
                   "telegram.send_message",
                   connect_id,
                   %{"chat_id" => "42001", "text" => text},
                   %{"tool_call_id" => id, "tool_context" => %{"trusted_origin" => origin}}
                 )
      end

      telegram_origin = fn connect ->
        %{
          "provider" => "telegram",
          "source_actor_type" => "provider_user",
          "provider_context" => %{"connect_id" => connect}
        }
      end

      # A background reminder: the Router replied in Home and copies it here.
      send.("copy", "copy of a Home reply", %{
        "provider" => "internal",
        "source_actor_type" => "system"
      })

      # A message from another Telegram chat is not this chat's conversation.
      send.("other", "reply to another chat", telegram_origin.("imc-other"))
      send.("answer", "answer in Telegram", telegram_origin.(connect_id))
      assert length(MockProviderRuntime.requests(:telegram_api)) == 3

      # History writes run in the background; read Home after all of them end.
      SystemsClock.settle()

      assert platform_messages!(group_id) == [
               %{
                 "provider" => "telegram",
                 "role" => "assistant",
                 "content" => [%{"type" => "text", "text" => "answer in Telegram"}]
               }
             ]
    end

    test "accepts only private inbound messages whose sender owns the linked chat", %{
      group_id: group_id,
      agent_id: agent_id,
      telegram_connect_id: connect_id
    } do
      {:ok, connect} =
        SalixIM.ProviderConnects.get_active_connect_by_id(group_id, connect_id, "telegram")

      assert {:error, :ignored} =
               SalixIM.ProviderHTTP.handle_telegram_update(connect, %{
                 "update_id" => 991,
                 "message" => %{
                   "message_id" => 1,
                   "text" => "wrong peer",
                   "chat" => %{"id" => 99999, "type" => "private"},
                   "from" => %{"id" => 99999}
                 }
               })

      assert {:error, :ignored} =
               SalixIM.ProviderHTTP.handle_telegram_update(connect, %{
                 "update_id" => 992,
                 "message" => %{
                   "message_id" => 2,
                   "text" => "group message",
                   "chat" => %{"id" => 42001, "type" => "supergroup"},
                   "from" => %{"id" => 42001}
                 }
               })

      SalixAgent.LLM.Mock.script([{:final, "ack"}])

      assert {:ok, :queued} =
               SalixIM.ProviderHTTP.handle_telegram_update(connect, %{
                 "update_id" => 993,
                 "message" => %{
                   "message_id" => 3,
                   "text" => "correct private peer",
                   "chat" => %{"id" => 42001, "type" => "private"},
                   "from" => %{"id" => 42001, "is_bot" => false}
                 }
               })

      assert_router_session_delivery(
        connect["tenant_id"],
        group_id,
        agent_id,
        "im_provider:telegram:#{connect_id}:993",
        "correct private peer"
      )
    end
  end

  describe "call_api/4 telegram media" do
    setup %{tenant: tenant, group_id: group_id} do
      SalixIM.Provider.Feishu.API.reset_token_cache()
      start_supervised!(MockProviderRuntime)
      base_url = BanditServer.serve!(MockProviderRuntime)
      prev = SystemsRuntime.get_env(:salix_im, :telegram_api_base_url)
      SystemsRuntime.put_env(:salix_im, :telegram_api_base_url, "#{base_url}")
      on_exit(fn -> restore(:salix_im, :telegram_api_base_url, prev) end)

      seed_connect(group_id, "tg-media", "telegram", %{
        "tenant_id" => tenant,
        "status" => "connected",
        "bot_token" => "tg-media-token",
        "bot_user_id" => "900",
        "bot_username" => "bridge_bot"
      })

      %{telegram_connect_id: "tg-media"}
    end

    test "does not read arbitrary host paths", %{
      agent_id: agent_id,
      telegram_connect_id: connect_id
    } do
      seed_agent_vfs(agent_id, %{})
      host_path = host_file!("HOST-SECRET-TELEGRAM")

      assert {:error, message} =
               call(agent_id, "telegram", "telegram.send_document", connect_id, %{
                 "chat_id" => "42",
                 "path" => host_path
               })

      assert message =~ "file not found in agent VFS"
      assert MockProviderRuntime.requests(:telegram_api) == []
    end

    test "uploads bytes from agent VFS", %{
      agent_id: agent_id,
      telegram_connect_id: connect_id
    } do
      seed_agent_vfs(agent_id, %{"/attachments/report.pdf" => "PDF-VFS-BYTES"})

      assert {:ok, %{"message_id" => 77}} =
               call(agent_id, "telegram", "telegram.send_document", connect_id, %{
                 "chat_id" => "42",
                 "path" => "/attachments/report.pdf",
                 "caption" => "report"
               })

      [req] = MockProviderRuntime.requests(:telegram_api)
      assert req.token == "tg-media-token"
      assert req.method == "sendDocument"
      assert req.raw =~ "PDF-VFS-BYTES"
      assert req.raw =~ ~s(filename="report.pdf")
    end
  end

  describe "call_api/4 provider observations" do
    setup %{tenant: tenant, group_id: group_id} do
      connect =
        seed_connect(group_id, "fs-observations", "feishu", %{
          "tenant_id" => tenant,
          "status" => "connected",
          "app_id" => "cli_observations"
        })

      %{feishu_connect: connect}
    end

    test "fails closed when the observed-user projection cannot be listed", %{
      agent_id: agent_id,
      feishu_connect: connect
    } do
      assert :ok =
               SalixIM.ProviderObservations.upsert_feishu_user(connect, %{
                 "open_id" => "ou_observed",
                 "name" => "Observed User"
               })

      assert {:ok, %{"users" => [%{"open_id" => "ou_observed"}]}} =
               call(
                 agent_id,
                 "feishu",
                 "feishu.list_observed_users",
                 connect["connect_id"],
                 %{"query" => "Observed", "limit" => 50}
               )

      prefix = Keys.ctl_im_feishu_users_prefix(connect["connect_id"])
      :ok = SalixStore.S3.Fake.set_fault({:fail, 503, :list, prefix})

      assert {:error, _reason} =
               call(
                 agent_id,
                 "feishu",
                 "feishu.list_observed_users",
                 connect["connect_id"],
                 %{"query" => "Observed", "limit" => 50}
               )

      key = Keys.ctl_im_feishu_user(connect["connect_id"], "ou_observed")
      :ok = SalixStore.S3.Fake.set_fault({:fail, 503, :get, key})

      assert {:error, _reason} =
               call(
                 agent_id,
                 "feishu",
                 "feishu.list_observed_users",
                 connect["connect_id"],
                 %{"query" => "Observed", "limit" => 50}
               )

      assert {:ok, _} = SalixStore.S3.put(key, "{not json")

      assert {:error, _reason} =
               call(
                 agent_id,
                 "feishu",
                 "feishu.list_observed_users",
                 connect["connect_id"],
                 %{"query" => "Observed", "limit" => 50}
               )
    end
  end

  describe "call_api/4 feishu media" do
    setup %{tenant: tenant, group_id: group_id} do
      start_supervised!(MockProviderRuntime)
      base_url = BanditServer.serve!(MockProviderRuntime)
      prev = SystemsRuntime.get_env(:salix_im, :feishu_api_base_url)

      SystemsRuntime.put_env(
        :salix_im,
        :feishu_api_base_url,
        "#{base_url}/open-apis"
      )

      on_exit(fn -> restore(:salix_im, :feishu_api_base_url, prev) end)

      seed_connect(group_id, "fs-media", "feishu", %{
        "tenant_id" => tenant,
        "status" => "connected",
        "app_id" => "cli_media",
        "app_secret" => "fs-secret",
        "verification_token" => "verify-token"
      })

      %{feishu_connect_id: "fs-media"}
    end

    test "Feishu callbacks are mirrored before Router relevance; a failed outbox insert fails the callback",
         %{group_id: group_id, feishu_connect_id: connect_id} do
      previous = SystemsRuntime.get_env(:salix_im, :feishu_message_mirror_mod)
      SystemsRuntime.put_env(:salix_im, :feishu_message_mirror_mod, FeishuMirrorFake)
      on_exit(fn -> restore(:salix_im, :feishu_message_mirror_mod, previous) end)

      SalixStore.Repo.query!("TRUNCATE feishu_mirror_outbox, feishu_mirror_containers")

      {:ok, connect} =
        SalixIM.ProviderConnects.get_active_connect_by_id(group_id, connect_id, "feishu")

      chatter = %{
        "schema" => "2.0",
        "header" => %{
          "event_type" => "im.message.receive_v1",
          "app_id" => "cli_media",
          "token" => "verify-token"
        },
        "event" => %{
          "sender" => %{"sender_id" => %{"open_id" => "ou_peer"}, "sender_type" => "user"},
          "message" => %{
            "message_id" => "om_chatter",
            "chat_id" => "oc_team",
            "chat_type" => "group",
            "message_type" => "text",
            "create_time" => "1784000000000",
            "content" => Jason.encode!(%{"text" => "发布计划 release plan"})
          }
        }
      }

      # The Router ignores unaddressed group chatter; the mirror keeps it.
      assert {:error, {:ignored, _reason}} =
               SalixIM.ProviderHTTP.handle_feishu_event(
                 connect,
                 chatter,
                 [],
                 Jason.encode!(chatter)
               )

      recall = %{
        "schema" => "2.0",
        "header" => %{
          "event_type" => "im.message.recalled_v1",
          "app_id" => "cli_media",
          "token" => "verify-token"
        },
        "event" => %{
          "message_id" => "om_chatter",
          "chat_id" => "oc_team",
          "recall_time" => "1784000005000"
        }
      }

      assert {:error, :ignored} =
               SalixIM.ProviderHTTP.handle_feishu_event(
                 connect,
                 recall,
                 [],
                 Jason.encode!(recall)
               )

      assert {:ok, [post, tombstone]} = SalixStore.FeishuMirrorOutbox.claim(10, 60_000)

      assert %{
               "tenant_id" => tenant_id,
               "app_id" => "cli_media",
               "chat_id" => "oc_team",
               "message_id" => "om_chatter",
               "text" => "发布计划 release plan",
               "deleted" => false,
               "ingest_source" => "webhook"
             } = post.row

      assert tenant_id == connect["tenant_id"]
      assert tombstone.row["deleted"] and tombstone.row["version"] > post.row["version"]

      previous_outbox = SystemsRuntime.get_env(:salix_im, :feishu_message_mirror_outbox)
      SystemsRuntime.put_env(:salix_im, :feishu_message_mirror_outbox, FeishuMirrorFailingOutbox)
      on_exit(fn -> restore(:salix_im, :feishu_message_mirror_outbox, previous_outbox) end)

      # Feishu retries a callback that did not succeed; the event is not lost.
      capture_log(fn ->
        assert {:error, :outbox_unavailable} =
                 SalixIM.ProviderHTTP.handle_feishu_event(
                   connect,
                   chatter,
                   [],
                   Jason.encode!(chatter)
                 )
      end)
    end

    test "feishu.search_messages searches the app-scoped mirror with stale and coverage marks", %{
      agent_id: agent_id,
      group_id: group_id,
      feishu_connect_id: connect_id
    } do
      SalixStore.Repo.query!("TRUNCATE feishu_mirror_outbox, feishu_mirror_containers")

      {:ok, connect} =
        SalixIM.ProviderConnects.get_active_connect_by_id(group_id, connect_id, "feishu")

      tenant_id = connect["tenant_id"]

      for {app, env, value} <- [
            {:salix_im, :feishu_message_mirror_mod, FeishuMirrorFake},
            {:salix_im, :feishu_mirror_reader_mod, FeishuMirrorFake}
          ] do
        previous = SystemsRuntime.get_env(app, env)
        SystemsRuntime.put_env(app, env, value)
        on_exit(fn -> restore(app, env, previous) end)
      end

      mirror_row = fn message_id, create_ms, content, text ->
        %{
          "tenant_id" => tenant_id,
          "app_id" => "cli_media",
          "chat_id" => "oc_team",
          "message_id" => message_id,
          "create_time_us" => create_ms * 1_000,
          "version" => create_ms * 2_000,
          "root_id" => "",
          "parent_id" => "",
          "thread_id" => "",
          "chat_type" => "group",
          "message_type" => if(String.contains?(content, "image_key"), do: "image", else: "text"),
          "actor_kind" => "user",
          "actor_id" => "ou_peer",
          "actor_label" => "Peer",
          "text" => text,
          "content" => content,
          "file_count" => if(String.contains?(content, "image_key"), do: 1, else: 0)
        }
      end

      FeishuMirrorFake.setup(SystemsRuntime.Proc.self(), [
        mirror_row.(
          "om_new",
          1_784_000_002_000,
          ~s({"text":"@_user_1 部署 done"}),
          "@Alice 部署 done"
        ),
        mirror_row.("om_img", 1_784_000_001_000, ~s({"image_key":"img_1"}), ""),
        %{mirror_row.("om_other_app", 1_784_000_000_000, "{}", "部署") | "app_id" => "cli_other"}
      ])

      {:ok, pending} =
        SalixIM.FeishuMessageMirror.Row.from_history(
          connect,
          %{
            "message_id" => "om_img",
            "chat_id" => "oc_team",
            "msg_type" => "image",
            "create_time" => "1784000001000",
            "body" => %{"content" => ~s({"image_key":"img_1"})}
          },
          0
        )

      :ok = SalixStore.FeishuMirrorOutbox.append(pending)

      assert {:ok, page} =
               call(agent_id, "feishu", "feishu.search_messages", connect_id, %{
                 "query" => "in:oc_team from:ou_peer 部署 -draft after:2026-01-01",
                 "count" => 1
               })

      assert_receive {:feishu_mirror_search, scope, opts}
      assert scope == %{"tenant_id" => tenant_id, "app_id" => "cli_media"}
      assert opts[:chat_id] == "oc_team"
      assert opts[:actor_id] == "ou_peer"
      assert opts[:patterns] == ["%部署%"]
      assert opts[:exclude_patterns] == ["%draft%"]
      assert opts[:after_us] == 1_767_225_600_000_000
      assert opts[:limit] == 1

      assert [%{"message_id" => "om_new", "text" => "@Alice 部署 done"} = hit] = page["messages"]
      assert hit["sender"]["name"] == "Peer"
      assert hit["create_time"] == "1784000002000"
      refute hit["stale"]
      assert page["has_more"]
      assert page["incomplete"] == %{"reason" => "not_synced"}

      cursor = page["response_metadata"]["next_cursor"]

      assert {:ok, next} =
               call(agent_id, "feishu", "feishu.search_messages", connect_id, %{
                 "query" => "in:oc_team from:ou_peer 部署 -draft after:2026-01-01",
                 "cursor" => cursor
               })

      assert_receive {:feishu_mirror_search, _scope, next_opts}
      assert next_opts[:cursor_ts_us] == 1_784_000_002_000_000
      assert next_opts[:cursor_message_id] == "om_new"

      assert [%{"message_id" => "om_img", "stale" => true, "attachments" => [image]}] =
               Enum.take(next["messages"], 1)

      assert image["resource_type"] == "image"
      assert String.starts_with?(image["resource_ref"], "fr2.")

      for {params, reason} <- [
            {%{"query" => "from:U12345678 部署"}, "from: requires"},
            {%{"query" => "in:general 部署"}, "in: requires a chat id"},
            {%{"query" => "部署", "page" => 2}, "invalid_arguments"},
            {%{"query" => "部署", "cursor" => "bm90LWEtY3Vyc29y"}, "invalid_arguments"}
          ] do
        assert {:error, error} =
                 call(agent_id, "feishu", "feishu.search_messages", connect_id, params)

        assert error =~ reason
      end

      SystemsRuntime.put_env(
        :salix_im,
        :feishu_message_mirror_mod,
        SalixIM.FeishuMessageMirror.Noop
      )

      assert {:error, unavailable} =
               call(agent_id, "feishu", "feishu.search_messages", connect_id, %{"query" => "部署"})

      assert unavailable =~ "not configured"
    end

    test "direct Feishu delivery uses exact targets and deterministic provider UUIDs", %{
      group_id: group_id,
      feishu_connect_id: connect_id
    } do
      previous = SystemsRuntime.get_env(:salix_im, :feishu_direct_delivery_mod)

      SystemsRuntime.put_env(
        :salix_im,
        :feishu_direct_delivery_mod,
        SalixIM.Ports.FeishuDirectDelivery.Production
      )

      on_exit(fn -> restore(:salix_im, :feishu_direct_delivery_mod, previous) end)

      assert {:ok, connect} =
               SalixIM.ProviderConnects.get_active_connect_by_id(
                 group_id,
                 connect_id,
                 "feishu"
               )

      calendar_operation = "calendar-notify:occurrence-1"

      assert {:ok, %{"message_id" => "om_sent"}} =
               SalixIM.Ports.FeishuDirectDelivery.post_text(
                 connect,
                 %{"chat_id" => "oc_calendar", "chat_type" => "group"},
                 "Calendar reminder",
                 %{"mode" => "none", "users" => []},
                 calendar_operation
               )

      [calendar_request] = MockProviderRuntime.requests(:feishu_message)
      assert calendar_request.query["receive_id_type"] == "chat_id"
      assert calendar_request.params["receive_id"] == "oc_calendar"

      assert calendar_request.params["uuid"] ==
               deterministic_feishu_uuid(
                 "feishu.send_text",
                 "oc_calendar",
                 calendar_operation
               )

      meeting_operation = "meeting:mtg-1:joining"

      assert {:ok, %{"message_id" => "om_reply_sent"}} =
               SalixIM.Ports.FeishuDirectDelivery.post_text(
                 connect,
                 %{
                   "chat_id" => "oc_meeting",
                   "chat_type" => "group",
                   "root_message_id" => "om_meeting_root",
                   "message_thread_id" => "omt_meeting"
                 },
                 "Joining meeting",
                 %{"mode" => "all"},
                 meeting_operation
               )

      [meeting_request] = MockProviderRuntime.requests(:feishu_reply)
      assert meeting_request.message_id == "om_meeting_root"
      assert meeting_request.params["reply_in_thread"] == true

      assert meeting_request.params["uuid"] ==
               deterministic_feishu_uuid(
                 "feishu.reply_text",
                 "om_meeting_root",
                 meeting_operation
               )
    end

    test "provider conversation delivery replies with one Feishu file and no placeholder text",
         %{
           agent_id: agent_id,
           group_id: group_id,
           feishu_connect_id: connect_id
         } do
      conversation_id = Ids.new_conversation_id()
      message_id = Ids.new_message_id()
      participant_id = Ids.new_participant_id()
      file_path = "/attachments/transcript.txt"

      seed_group_conversation(group_id, agent_id, %{"conversation_id" => conversation_id})
      seed_agent_vfs(agent_id, %{file_path => "MEETING-TRANSCRIPT"})
      assert {:ok, entry} = SalixAgent.AgentWorkspace.entry(agent_id, file_path)
      blob_ref = entry["ref"]

      seed_agent_vfs(agent_id, %{file_path => "MUTATED-AFTER-QUEUE"})

      delivery = %{
        "delivery_id" => "#{group_id}:#{conversation_id}:#{message_id}:#{participant_id}",
        "status" => "pending",
        "agent_group_id" => group_id,
        "conversation_id" => conversation_id,
        "message_id" => message_id,
        "participant_id" => participant_id,
        "participant_actor_type" => "provider",
        "participant_provider" => "feishu",
        "participant_payload" => %{
          "connect_id" => connect_id,
          "chat_id" => "oc_meeting",
          "root_message_id" => "om_meeting_root",
          "message_thread_id" => "omt_meeting"
        },
        "operation_ref" => "meeting-artifact-transcript",
        "source_agent_id" => agent_id,
        "message_content" => [
          %{
            "type" => "file",
            "path" => file_path,
            "title" => "transcript.txt",
            "blob_ref" => blob_ref
          }
        ],
        "message_created_at" => SystemsClock.system_time(:millisecond)
      }

      {participant_id, message_id} =
        put_delivery!(group_id, conversation_id, participant_id, delivery)

      diagnostic =
        wake_delivery_and_wait!(
          group_id,
          conversation_id,
          participant_id,
          message_id,
          "delivered"
        )

      delivered = diagnostic["delivery"]["delivery_result"]

      assert delivered["text"] == nil
      assert length(delivered["files"]) == 1
      assert [upload] = MockProviderRuntime.requests(:feishu_file_upload)
      assert upload.raw =~ "MEETING-TRANSCRIPT"
      refute upload.raw =~ "MUTATED-AFTER-QUEUE"

      assert [reply] = MockProviderRuntime.requests(:feishu_reply)
      assert reply.message_id == "om_meeting_root"
      assert reply.params["msg_type"] == "file"
      assert reply.params["reply_in_thread"] == true
      assert Jason.decode!(reply.params["content"]) == %{"file_key" => "file-key-1"}

      assert :ok =
               ConversationServer.wake_participant(group_id, conversation_id, participant_id)

      assert length(MockProviderRuntime.requests(:feishu_reply)) == 1
    end

    test "meeting activation capability is exact-topic, exact-mention, expiring, and reply-only",
         %{
           tenant: tenant,
           agent_id: agent_id,
           group_id: group_id,
           feishu_connect_id: connect_id
         } do
      assert {:ok, connect} = SalixIM.ProviderConnects.find_active_im_connect_by_id(connect_id)
      assert {:ok, signing_key} = SalixIM.Provider.Feishu.API.resource_ref_signing_key(connect)

      target = %{
        "message_id" => "om_activation_root",
        "chat_id" => "oc_activation",
        "chat_type" => "p2p",
        "thread_id" => "",
        "reply_in_thread" => false
      }

      ref_scope =
        SalixIM.Provider.Feishu.MeetingActivationAuthorization.ref_scope(group_id, connect_id)

      issue_ref = fn expires_at ->
        assert {:ok, ref} =
                 SalixIM.Provider.Feishu.MeetingActivationRef.encode(
                   ref_scope,
                   signing_key,
                   %{
                     "meeting_id" => "mtg_activation_capability",
                     "expires_at" => expires_at,
                     "target" => target,
                     "allowed_mentions" => [
                       %{"user_id" => "ou_alice", "name" => "Alice"}
                     ]
                   }
                 )

        ref
      end

      production_agent_delivery = SystemsRuntime.get_env(:salix_im, :agent_delivery_mod)

      production_delivery_test_pid =
        SystemsRuntime.get_env(:salix_im, :fake_agent_delivery_test_pid)

      source_context = fn ref, suffix ->
        source_id = "meeting-activation:mtg_activation_capability:#{suffix}"

        current_agent_delivery = SystemsRuntime.get_env(:salix_im, :agent_delivery_mod)

        current_delivery_test_pid =
          SystemsRuntime.get_env(:salix_im, :fake_agent_delivery_test_pid)

        restore(:salix_im, :agent_delivery_mod, production_agent_delivery)
        restore(:salix_im, :fake_agent_delivery_test_pid, production_delivery_test_pid)

        # context_only is no_wake by design and normally joins the next
        # natural Router turn. This test needs to inspect its sealed origin
        # without creating such a turn, so quiesce first: delivery's ordinary
        # cold-start recovery absorbs the markerless inbox item into the
        # pending session queue without invoking the model.
        try do
          SalixAgent.TestSupport.stop_all_agents()

          assert {:ok, :queued} =
                   SalixIM.ProviderConnects.enqueue_group_router_im_provider_message(
                     group_id,
                     "meeting activation",
                     Map.merge(target, %{
                       "provider" => "feishu",
                       "connect_id" => connect_id,
                       "meeting_activation_ref" => ref,
                       "event_type" => "meeting.completed",
                       "router_activation_mode" => "context_only"
                     }),
                     source_id
                   )

          # The staged engine and its drain retired in A2 §3.4: the enqueue's
          # delivery commits straight into the router session ledger, and
          # router_session_trusted_origin!/4 already polls that ledger.
          trusted_origin = router_session_trusted_origin!(group_id, agent_id, source_id)

          %{
            "tool_context" => %{
              "source_message_ids" => [source_id],
              "source_message_id" => source_id,
              "trusted_origin" => trusted_origin,
              "trusted_origins" => [trusted_origin]
            }
          }
        after
          restore(:salix_im, :agent_delivery_mod, current_agent_delivery)
          restore(:salix_im, :fake_agent_delivery_test_pid, current_delivery_test_pid)
        end
      end

      valid_context =
        issue_ref.(@valid_meeting_activation_expires_at)
        |> source_context.("valid")

      params =
        Map.merge(target, %{
          "text" => "Assigned",
          "mentions" => [%{"user_id" => "ou_alice", "name" => "Alice"}]
        })

      assert {:ok, %{"message_id" => "om_reply_sent"}} =
               call(agent_id, "feishu", "feishu.reply_text", connect_id, params, valid_context)

      target_b = %{
        "message_id" => "om_activation_b",
        "chat_id" => "oc_activation_b",
        "chat_type" => "group",
        "thread_id" => "omt_activation_b",
        "reply_in_thread" => true
      }

      assert {:ok, ref_b} =
               SalixIM.Provider.Feishu.MeetingActivationRef.encode(
                 ref_scope,
                 signing_key,
                 %{
                   "meeting_id" => "mtg_activation_capability_b",
                   "expires_at" => @valid_meeting_activation_expires_at,
                   "target" => target_b,
                   "allowed_mentions" => []
                 }
               )

      context_b = source_context.(ref_b, "valid-b")

      multi_context = %{
        "tool_context" => %{
          "source_message_ids" => [
            get_in(valid_context, ["tool_context", "source_message_id"]),
            get_in(context_b, ["tool_context", "source_message_id"])
          ],
          "source_message_id" => get_in(context_b, ["tool_context", "source_message_id"]),
          "trusted_origin" => get_in(context_b, ["tool_context", "trusted_origin"]),
          "trusted_origins" =>
            get_in(valid_context, ["tool_context", "trusted_origins"]) ++
              get_in(context_b, ["tool_context", "trusted_origins"])
        }
      }

      assert {:ok, %{"message_id" => "om_reply_sent"}} =
               call(agent_id, "feishu", "feishu.reply_text", connect_id, params, multi_context)

      assert {:ok, %{"message_id" => "om_reply_sent"}} =
               call(
                 agent_id,
                 "feishu",
                 "feishu.reply_text",
                 connect_id,
                 Map.put(target_b, "text", "Assigned B"),
                 multi_context
               )

      assert {:error, multi_error} =
               call(
                 agent_id,
                 "feishu",
                 "feishu.reply_text",
                 connect_id,
                 Map.merge(target_b, %{"message_id" => "om_other", "text" => "unrelated"}),
                 multi_context
               )

      assert multi_error =~ "meeting activation is not authorized"

      activation_tool_ctx = %{
        agent_id: agent_id,
        role: "router",
        runtime_kind: :internal,
        session_id:
          SalixIM.ProviderConnects.agent_group_router_session_id(agent_id, group_id) |> elem(1),
        group_id: group_id,
        source_message_ids: get_in(multi_context, ["tool_context", "source_message_ids"]),
        source_message_id: get_in(multi_context, ["tool_context", "source_message_id"]),
        trusted_origin: get_in(multi_context, ["tool_context", "trusted_origin"]),
        trusted_origins: get_in(multi_context, ["tool_context", "trusted_origins"])
      }

      # An unbound continuation still carries its complete sealed grant set.
      # Unlike a current Slack request, it must not silently lose provenance.
      assert %{"message_id" => "om_reply_sent"} =
               SalixAgent.Tools.ImRouter.call_dynamic_operation(
                 "im_api.feishu.reply_text",
                 Map.put(params, "connect_id", connect_id),
                 Map.delete(activation_tool_ctx, :trusted_origin)
               )
               |> Jason.decode!()

      assert_raise RuntimeError, ~r/missing_activation_origin/, fn ->
        SalixAgent.Tools.ImRouter.call_dynamic_operation(
          "im_api.internal.task.create",
          %{
            "connect_id" => "internal",
            "agent_id" => agent_id,
            "content" => "Missing provenance must fail before target lookup.",
            "schedule" => %{"interval_minutes" => 5}
          },
          Map.drop(activation_tool_ctx, [:trusted_origin, :trusted_origins])
        )
      end

      {:ok, activation_worker} =
        create_control_agent(
          %{"name" => "Activation worker", "group_id" => group_id, "role" => "worker"},
          tenant
        )

      assert {:error, create_error} =
               call(
                 agent_id,
                 "internal",
                 "internal.task.create",
                 "internal",
                 %{
                   "agent_id" => activation_worker["agent_id"],
                   "content" => "send a delayed cross-topic report",
                   "schedule" => %{"interval_minutes" => 1}
                 },
                 %{"tool_context" => activation_tool_ctx}
               )

      assert create_error =~ "meeting_activation_schedule_not_authorized"

      # Exercise the real IM tool projection as well as direct Provider calls:
      # a current meeting remains restricted even after provider source isolation.
      assert_raise RuntimeError, ~r/meeting_activation_schedule_not_authorized/, fn ->
        SalixAgent.Tools.ImRouter.call_dynamic_operation(
          "im_api.internal.task.create",
          %{
            "connect_id" => "internal",
            "agent_id" => activation_worker["agent_id"],
            "content" => "A meeting must not authorize recurring work.",
            "schedule" => %{"interval_minutes" => 5}
          },
          activation_tool_ctx
        )
      end

      assert {:ok, %{"data" => conversations_after_rejection}} =
               Conversations.list_group_conversations(group_id, limit: 100)

      refute Enum.any?(conversations_after_rejection, fn conversation ->
               conversation["kind"] == "agent_task" and
                 get_in(conversation, ["schedule", "schedule_id"]) not in [nil, ""]
             end)

      assert_raise RuntimeError, ~r/meeting_activation_schedule_not_authorized/, fn ->
        SalixAgent.Tools.Schedules.create_schedule(
          %{"run_at" => "2027-01-02T09:50:00+08:00", "prompt" => "send elsewhere"},
          activation_tool_ctx
        )
      end

      existing_task_conversation =
        seed_group_conversation(group_id, agent_id, %{
          "kind" => "agent_task",
          "title" => "Pre-activation unbound task",
          "source_refs" => %{},
          "messages" => [
            %{"content" => "ordinary task", "source_message_id" => "ordinary-task-source"}
          ]
        })

      assert {:error, update_error} =
               call(
                 agent_id,
                 "internal",
                 "internal.task.update",
                 "internal",
                 %{
                   "conversation_id" => existing_task_conversation["conversation_id"],
                   "command" => "send elsewhere",
                   "schedule" => %{"interval_minutes" => 1}
                 },
                 %{"tool_context" => activation_tool_ctx}
               )

      assert update_error =~ "meeting_activation_task_update_not_authorized"

      assert {:ok, unchanged_task} =
               Conversations.get_group_conversation(
                 group_id,
                 existing_task_conversation["conversation_id"]
               )

      assert unchanged_task["source_refs"] == %{}
      refute get_in(unchanged_task, ["schedule", "schedule_id"])

      assert {:ok, %{"meeting_activation_refs" => inherited_refs}} =
               SalixIM.Provider.Feishu.MeetingActivationAuthorization.provenance_for_tool_context(
                 group_id,
                 activation_tool_ctx
               )

      assert length(inherited_refs) == 2

      task_conversation =
        seed_group_conversation(group_id, agent_id, %{
          "kind" => "agent_task",
          "title" => "Inherited activation provenance",
          "source_refs" => %{"meeting_activation_refs" => inherited_refs},
          "messages" => [
            %{"content" => "task report", "source_message_id" => "activation-task-report"}
          ]
        })

      assert {:ok, task_messages} =
               Conversations.list_group_conversation_messages(
                 group_id,
                 task_conversation["conversation_id"],
                 limit: 10
               )

      task_message_id = hd(task_messages)["message_id"]

      inherited_source =
        "groupconv:#{task_conversation["conversation_id"]}:#{task_message_id}:#{Ids.new_participant_id()}"

      inherited_context = %{
        "tool_context" => %{
          "source_message_ids" => [inherited_source],
          "source_message_id" => inherited_source
        }
      }

      assert {:ok, %{"message_id" => "om_reply_sent"}} =
               call(
                 agent_id,
                 "feishu",
                 "feishu.reply_text",
                 connect_id,
                 Map.put(target_b, "text", "delegated result"),
                 inherited_context
               )

      SystemsRuntime.put_env(:salix_im, :agent_delivery_mod, FakeAgentDelivery)
      SystemsRuntime.put_env(:salix_im, :fake_agent_delivery_test_pid, SystemsRuntime.Proc.self())

      on_exit(fn ->
        restore(:salix_im, :agent_delivery_mod, production_agent_delivery)
        restore(:salix_im, :fake_agent_delivery_test_pid, production_delivery_test_pid)
      end)

      derived_task_id = Ids.new_conversation_id()

      derived_task =
        seed_group_conversation(group_id, activation_worker["agent_id"], %{
          "conversation_id" => derived_task_id,
          "kind" => "agent_task",
          "title" => "Activation-derived task",
          "source_refs" => %{
            "meeting_activation_refs" => inherited_refs,
            "parent_conversation_id" => task_conversation["conversation_id"]
          },
          "participants" => [
            agent_participant(
              derived_task_id,
              activation_worker["agent_id"],
              "worker",
              "ses1_1100000000000000101",
              %{"actor_type" => "agent", "role_label" => "worker"}
            ),
            agent_participant(
              derived_task_id,
              agent_id,
              "delegator",
              "ses1_1100000000000000102",
              %{"actor_type" => "agent", "role_label" => "delegator"}
            )
          ]
        })

      report_params = %{
        "conversation_id" => derived_task["conversation_id"],
        "request_id" => "activation-worker-report",
        "content" => [%{"type" => "text", "text" => "worker result"}]
      }

      assert {:error,
              "im_api.internal.send_message accepts only conversation_id, content, request_id, delivery_filter, mentions, reply_to_message_id"} =
               call(
                 activation_worker["agent_id"],
                 "internal",
                 "internal.send_message",
                 "internal",
                 Map.put(report_params, "conversation_update", %{"source_refs" => %{}}),
                 inherited_context
               )

      assert {:ok, %{"message_id" => report_message_id}} =
               call(
                 activation_worker["agent_id"],
                 "internal",
                 "internal.send_message",
                 "internal",
                 report_params,
                 inherited_context
               )

      assert {:ok, derived_messages} =
               Conversations.list_group_conversation_messages(
                 group_id,
                 derived_task["conversation_id"],
                 limit: 10
               )

      report_message = Enum.find(derived_messages, &(&1["message_id"] == report_message_id))
      assert report_message["metadata"]["meeting_activation_refs"] == inherited_refs

      delegator_participant_id =
        participant_id_for_agent!(group_id, derived_task["conversation_id"], agent_id)

      transitive_source =
        "groupconv:#{derived_task["conversation_id"]}:#{report_message_id}:#{delegator_participant_id}"

      transitive_context = %{
        "tool_context" => %{
          "source_message_ids" => [transitive_source],
          "source_message_id" => transitive_source
        }
      }

      assert {:ok, %{"message_id" => "om_reply_sent"}} =
               call(
                 agent_id,
                 "feishu",
                 "feishu.reply_text",
                 connect_id,
                 Map.put(target_b, "text", "worker result visible"),
                 transitive_context
               )

      assert {:error, transitive_cross_topic_error} =
               call(
                 agent_id,
                 "feishu",
                 "feishu.send_text",
                 connect_id,
                 %{
                   "receive_id" => "oc_other",
                   "text" => "escaped worker result",
                   "mention_all" => true
                 },
                 transitive_context
               )

      assert transitive_cross_topic_error =~ "meeting activation is not authorized"

      wake_delivery_and_wait!(
        group_id,
        derived_task["conversation_id"],
        delegator_participant_id,
        report_message_id,
        "delivered"
      )

      # The earlier Router activation deliveries are asynchronous and may
      # still arrive after this test installs FakeAgentDelivery. Select the
      # exact transitive report instead of consuming the first delivery for
      # the same agent.
      settle_receive(
        {:agent_delivery, ^agent_id, delivered_payload,
         [{:source_message_id, ^transitive_source} | _] = _delivered_opts}
      )

      assert [%{content: derived_source_context}] = delivered_payload.pre_deliveries
      assert derived_source_context =~ "capability-bound Feishu meeting activation"
      assert derived_source_context =~ "im_api.feishu.reply_text"
      assert derived_source_context =~ "om_activation_b"
      assert derived_source_context =~ "oc_activation_b"
      refute derived_source_context =~ "notify the user in parent_conversation_id"
      refute derived_source_context =~ "internal.send_message with connect_id=\"internal\""

      assert {:error, inherited_error} =
               call(
                 agent_id,
                 "feishu",
                 "feishu.send_text",
                 connect_id,
                 %{"receive_id" => "oc_other", "text" => "cross-topic"},
                 inherited_context
               )

      assert inherited_error =~ "meeting activation is not authorized"

      hundred_mentions =
        Enum.map(0..99, fn index ->
          %{
            "user_id" => "ou_" <> String.pad_leading(Integer.to_string(index), 27, "0"),
            "name" => "Alice #{index}"
          }
        end)

      assert {:ok, hundred_owner_ref} =
               SalixIM.Provider.Feishu.MeetingActivationRef.encode(
                 ref_scope,
                 signing_key,
                 %{
                   "meeting_id" => "mtg_activation_100_owners",
                   "expires_at" => @valid_meeting_activation_expires_at,
                   "target" => target,
                   "allowed_mentions" => hundred_mentions
                 }
               )

      assert byte_size(hundred_owner_ref) > 8_192
      hundred_owner_context = source_context.(hundred_owner_ref, "100-owners")

      assert {:ok, %{"message_id" => "om_reply_sent"}} =
               call(
                 agent_id,
                 "feishu",
                 "feishu.reply_text",
                 connect_id,
                 Map.merge(target, %{
                   "text" => "owner 99 assigned",
                   "mentions" => [List.last(hundred_mentions)]
                 }),
                 hundred_owner_context
               )

      for forbidden_params <- [
            put_in(params, ["mentions", Access.at(0), "user_id"], "ou_victim"),
            put_in(params, ["mentions", Access.at(0), "name"], "Forged Alice"),
            Map.put(params, "chat_id", "oc_other"),
            Map.put(params, "message_id", "om_other"),
            Map.put(params, "mention_all", true)
          ] do
        assert {:error, error} =
                 call(
                   agent_id,
                   "feishu",
                   "feishu.reply_text",
                   connect_id,
                   forbidden_params,
                   valid_context
                 )

        assert error =~ "meeting activation is not authorized"
      end

      assert {:error, operation_error} =
               call(
                 agent_id,
                 "feishu",
                 "feishu.send_text",
                 connect_id,
                 %{"receive_id" => "oc_activation", "text" => "cross operation"},
                 valid_context
               )

      assert operation_error =~ "meeting activation is not authorized"

      expired_context =
        issue_ref.(0)
        |> source_context.("expired")

      assert {:error, expired_error} =
               call(agent_id, "feishu", "feishu.reply_text", connect_id, params, expired_context)

      assert expired_error =~ "meeting activation is not authorized"

      ref = issue_ref.(@valid_meeting_activation_expires_at)
      reply_count_before_tampering = length(MockProviderRuntime.requests(:feishu_reply))
      url64_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

      same_byte_noncanonical_alias = fn encoded ->
        last = binary_part(encoded, byte_size(encoded) - 1, 1)
        {last_index, 1} = :binary.match(url64_alphabet, last)

        canonical_stride =
          case rem(byte_size(encoded), 4) do
            2 -> 16
            3 -> 4
          end

        assert rem(last_index, canonical_stride) == 0

        binary_part(encoded, 0, byte_size(encoded) - 1) <>
          binary_part(url64_alphabet, last_index + 1, 1)
      end

      ["fma1", canonical_payload, canonical_mac] = String.split(ref, ".")
      tampered_mac = same_byte_noncanonical_alias.(canonical_mac)

      tampered_mac_ref = "fma1.#{canonical_payload}.#{tampered_mac}"

      assert Base.url_decode64!(canonical_mac, padding: false) ==
               Base.url_decode64!(tampered_mac, padding: false)

      tampered_mac_context = source_context.(tampered_mac_ref, "tampered-mac-alias")

      assert {:error, tampered_mac_error} =
               call(
                 agent_id,
                 "feishu",
                 "feishu.reply_text",
                 connect_id,
                 params,
                 tampered_mac_context
               )

      assert tampered_mac_error =~ "meeting activation is not authorized"

      tampered_payload = same_byte_noncanonical_alias.(canonical_payload)
      tampered_payload_ref = "fma1.#{tampered_payload}.#{canonical_mac}"

      assert Base.url_decode64!(canonical_payload, padding: false) ==
               Base.url_decode64!(tampered_payload, padding: false)

      tampered_payload_context =
        source_context.(tampered_payload_ref, "tampered-payload-alias")

      assert {:error, tampered_payload_error} =
               call(
                 agent_id,
                 "feishu",
                 "feishu.reply_text",
                 connect_id,
                 params,
                 tampered_payload_context
               )

      assert tampered_payload_error =~ "meeting activation is not authorized"

      first_mac_char = binary_part(canonical_mac, 0, 1)
      changed_first_mac_char = if first_mac_char == "A", do: "B", else: "A"

      changed_mac =
        changed_first_mac_char <> binary_part(canonical_mac, 1, byte_size(canonical_mac) - 1)

      changed_mac_ref = "fma1.#{canonical_payload}.#{changed_mac}"

      refute Base.url_decode64!(canonical_mac, padding: false) ==
               Base.url_decode64!(changed_mac, padding: false)

      changed_mac_context = source_context.(changed_mac_ref, "changed-mac-bytes")

      assert {:error, changed_mac_error} =
               call(
                 agent_id,
                 "feishu",
                 "feishu.reply_text",
                 connect_id,
                 params,
                 changed_mac_context
               )

      assert changed_mac_error =~ "meeting activation is not authorized"

      assert length(MockProviderRuntime.requests(:feishu_reply)) ==
               reply_count_before_tampering

      missing_source_id = "meeting-activation:missing-direct-router-source"

      missing_context = %{
        "tool_context" => %{
          "source_message_ids" => [missing_source_id],
          "source_message_id" => missing_source_id
        }
      }

      assert {:error, missing_error} =
               call(agent_id, "feishu", "feishu.reply_text", connect_id, params, missing_context)

      assert missing_error =~ "meeting activation is not authorized"

      missing_ref_source_id = "meeting-activation:missing-ref"

      current_agent_delivery = SystemsRuntime.get_env(:salix_im, :agent_delivery_mod)
      current_delivery_test_pid = SystemsRuntime.get_env(:salix_im, :fake_agent_delivery_test_pid)

      restore(:salix_im, :agent_delivery_mod, production_agent_delivery)
      restore(:salix_im, :fake_agent_delivery_test_pid, production_delivery_test_pid)

      missing_ref_origin =
        try do
          assert {:ok, :queued} =
                   SalixIM.ProviderConnects.enqueue_group_router_im_provider_message(
                     group_id,
                     "missing activation ref",
                     Map.merge(target, %{"provider" => "feishu", "connect_id" => connect_id}),
                     missing_ref_source_id
                   )

          router_session_message!(group_id, agent_id, missing_ref_source_id).trusted_origin
        after
          restore(:salix_im, :agent_delivery_mod, current_agent_delivery)
          restore(:salix_im, :fake_agent_delivery_test_pid, current_delivery_test_pid)
        end

      assert {:error, missing_ref_error} =
               call(
                 agent_id,
                 "feishu",
                 "feishu.reply_text",
                 connect_id,
                 params,
                 %{
                   "tool_context" => %{
                     "source_message_ids" => [missing_ref_source_id],
                     "source_message_id" => missing_ref_source_id,
                     "trusted_origin" => missing_ref_origin,
                     "trusted_origins" => [missing_ref_origin]
                   }
                 }
               )

      assert missing_ref_error =~ "meeting activation is not authorized"

      ordinary_sources =
        for index <- 1..64 do
          source_id = "ordinary-router-input-#{index}"

          assert {:ok, :queued} =
                   SalixIM.ProviderConnects.enqueue_group_router_im_provider_message(
                     group_id,
                     "ordinary #{index}",
                     Map.merge(target, %{
                       "provider" => "feishu",
                       "connect_id" => connect_id
                     }),
                     source_id
                   )

          source_id
        end

      overflow_sources =
        ordinary_sources ++ [get_in(valid_context, ["tool_context", "source_message_id"])]

      assert {:error, overflow_error} =
               call(
                 agent_id,
                 "feishu",
                 "feishu.send_text",
                 connect_id,
                 %{"receive_id" => "oc_other", "text" => "overflow fail closed"},
                 %{
                   "tool_context" => %{
                     "source_message_ids" => overflow_sources,
                     "source_message_id" => List.last(overflow_sources),
                     "trusted_origin" =>
                       get_in(valid_context, ["tool_context", "trusted_origin"]),
                     "trusted_origins" =>
                       get_in(valid_context, ["tool_context", "trusted_origins"])
                   }
                 }
               )

      assert overflow_error =~ "meeting activation is not authorized"

      hundred_source_overflow =
        for index <- 1..100, do: "direct-router-overflow-#{index}"

      assert {:error, hundred_source_error} =
               call(
                 agent_id,
                 "feishu",
                 "feishu.reply_text",
                 connect_id,
                 params,
                 %{
                   "tool_context" => %{
                     "source_message_ids" => hundred_source_overflow,
                     "source_message_id" => List.last(hundred_source_overflow)
                   }
                 }
               )

      assert hundred_source_error =~ "meeting activation is not authorized"
      # Includes the additional unbound-continuation call through ImRouter.
      assert length(MockProviderRuntime.requests(:feishu_reply)) == 7

      assert {:ok, _conversation} =
               SalixIM.RouterConversationProjection.get_group_router_conversation(group_id)
    end

    test "activation-bound internal messages cannot escape through provider participants",
         %{
           tenant: tenant,
           agent_id: agent_id,
           group_id: group_id,
           feishu_connect_id: feishu_connect_id
         } do
      slack_connect_id = "sl-activation-outbox"

      seed_connect(group_id, slack_connect_id, "slack", %{
        "tenant_id" => tenant,
        "workspace_id" => "T-activation-outbox",
        "bot_token" => "xoxb-activation-outbox",
        "oauth_completed_at" => 1,
        "status" => "connected"
      })

      assert {:ok, feishu_connect} =
               SalixIM.ProviderConnects.find_active_im_connect_by_id(feishu_connect_id)

      assert {:ok, signing_key} =
               SalixIM.Provider.Feishu.API.resource_ref_signing_key(feishu_connect)

      target = %{
        "message_id" => "om_activation_outbox_root",
        "chat_id" => "oc_activation_outbox",
        "chat_type" => "group",
        "thread_id" => "omt_activation_outbox",
        "reply_in_thread" => true
      }

      assert {:ok, activation_ref} =
               SalixIM.Provider.Feishu.MeetingActivationRef.encode(
                 SalixIM.Provider.Feishu.MeetingActivationAuthorization.ref_scope(
                   group_id,
                   feishu_connect_id
                 ),
                 signing_key,
                 %{
                   "meeting_id" => "mtg_activation_outbox",
                   "expires_at" => @valid_meeting_activation_expires_at,
                   "target" => target,
                   "allowed_mentions" => []
                 }
               )

      source_id = "meeting-activation:mtg_activation_outbox"

      assert {:ok, :queued} =
               SalixIM.ProviderConnects.enqueue_group_router_im_provider_message(
                 group_id,
                 "meeting activation",
                 Map.merge(target, %{
                   "provider" => "feishu",
                   "connect_id" => feishu_connect_id,
                   "meeting_activation_ref" => activation_ref
                 }),
                 source_id
               )

      activation_message = router_session_message!(group_id, agent_id, source_id)
      activation_origin = activation_message.trusted_origin

      activation_context = %{
        "tool_context" => %{
          "source_message_ids" => [source_id],
          "source_message_id" => source_id,
          "trusted_origin" => activation_origin,
          "trusted_origins" => [activation_origin]
        }
      }

      assert {:ok, %{"meeting_activation_refs" => inherited_refs}} =
               SalixIM.Provider.Feishu.MeetingActivationAuthorization.provenance_for_tool_context(
                 group_id,
                 activation_context["tool_context"]
               )

      escape_conversation_id = Ids.new_conversation_id()
      escape_agent_participant_id = Ids.new_participant_id()
      escape_feishu_participant_id = Ids.new_participant_id()
      escape_slack_participant_id = Ids.new_participant_id()

      escape_conversation =
        seed_group_conversation(group_id, agent_id, %{
          "conversation_id" => escape_conversation_id,
          "kind" => "agent_task",
          "title" => "Provider outbox escape target",
          "participants" => [
            agent_participant(
              escape_conversation_id,
              agent_id,
              escape_agent_participant_id,
              "ses1_1100000000000000201"
            ),
            %{
              "participant_id" => escape_feishu_participant_id,
              "actor_type" => "provider",
              "provider" => "feishu",
              "state" => "active",
              "notification_filter" => %{"messages" => "all", "statuses" => "none"},
              "payload" => %{
                "connect_id" => feishu_connect_id,
                "chat_id" => "oc_escape_target",
                "chat_type" => "group",
                "root_message_id" => "om_escape_target",
                "message_thread_id" => "omt_escape_target",
                "mentions" => %{"mode" => "all"}
              }
            },
            %{
              "participant_id" => escape_slack_participant_id,
              "actor_type" => "provider",
              "provider" => "slack",
              "state" => "active",
              "notification_filter" => %{"messages" => "all", "statuses" => "none"},
              "payload" => %{
                "connect_id" => slack_connect_id,
                "workspace_id" => "T-activation-outbox",
                "channel_id" => "C-escape-target",
                "thread_ts" => "1784610905.655859"
              }
            }
          ]
        })

      assert {:ok, %{"participants" => escape_participants}} =
               Conversations.list_group_conversation_participants(
                 group_id,
                 escape_conversation["conversation_id"]
               )

      escape_feishu_participant_id =
        Enum.find(escape_participants, &(&1["provider"] == "feishu"))["participant_id"]

      escape_slack_participant_id =
        Enum.find(escape_participants, &(&1["provider"] == "slack"))["participant_id"]

      assert {:ok, %{"message_id" => bound_message_id}} =
               call(
                 agent_id,
                 "internal",
                 "internal.send_message",
                 "internal",
                 %{
                   "conversation_id" => escape_conversation["conversation_id"],
                   "request_id" => "activation-provider-outbox-bound",
                   "content" => [%{"type" => "text", "text" => "bound coordination"}]
                 },
                 activation_context
               )

      assert {:ok, escape_messages} =
               Conversations.list_group_conversation_messages(
                 group_id,
                 escape_conversation["conversation_id"],
                 limit: 20
               )

      bound_message = Enum.find(escape_messages, &(&1["message_id"] == bound_message_id))
      assert bound_message["metadata"]["meeting_activation_refs"] == inherited_refs

      for participant_id <- [escape_feishu_participant_id, escape_slack_participant_id] do
        assert eventually(fn ->
                 case Conversations.get_group_conversation_participant(
                        group_id,
                        escape_conversation["conversation_id"],
                        participant_id
                      ) do
                   {:ok, participant} ->
                     participant["delivery_cursor_seq"] >= bound_message["seq"]

                   _ ->
                     false
                 end
               end)
      end

      assert MockProviderRuntime.requests(:feishu_reply) == []
      assert MockSlack.requests("chat.postMessage") == []

      assert {:ok, %{"message_id" => ordinary_message_id}} =
               call(
                 agent_id,
                 "internal",
                 "internal.send_message",
                 "internal",
                 %{
                   "conversation_id" => escape_conversation["conversation_id"],
                   "request_id" => "activation-provider-outbox-ordinary",
                   "content" => [%{"type" => "text", "text" => "ordinary visible result"}]
                 }
               )

      assert eventually(fn -> length(MockProviderRuntime.requests(:feishu_reply)) == 1 end)
      assert eventually(fn -> length(MockSlack.requests("chat.postMessage")) == 1 end)

      [ordinary_feishu_request] = MockProviderRuntime.requests(:feishu_reply)
      assert ordinary_feishu_request.message_id == "om_escape_target"

      assert ordinary_feishu_request.params["msg_type"] == "post"

      assert [
               [%{"tag" => "at", "user_id" => "all"}],
               [%{"tag" => "md", "text" => "ordinary visible result"}]
             ] =
               ordinary_feishu_request.params["content"]
               |> Jason.decode!()
               |> get_in(["zh_cn", "content"])

      [ordinary_slack_request] = MockSlack.requests("chat.postMessage")
      assert ordinary_slack_request.params["channel"] == "C-escape-target"
      assert ordinary_slack_request.params["thread_ts"] == "1784610905.655859"
      assert ordinary_slack_request.params["text"] == "ordinary visible result"

      assert {:ok, escape_messages} =
               Conversations.list_group_conversation_messages(
                 group_id,
                 escape_conversation["conversation_id"],
                 limit: 20
               )

      ordinary_message = Enum.find(escape_messages, &(&1["message_id"] == ordinary_message_id))
      refute Map.has_key?(ordinary_message["metadata"] || %{}, "meeting_activation_refs")

      protected_conversation =
        seed_group_conversation(group_id, agent_id, %{
          "kind" => "agent_task",
          "title" => "Protected activation task",
          "source_refs" => %{
            "meeting_activation_refs" => inherited_refs,
            "parent_conversation_id" => escape_conversation["conversation_id"]
          },
          "participants" => [
            agent_participant(
              Ids.new_conversation_id(),
              agent_id,
              Ids.new_participant_id(),
              "ses1_1100000000000000202"
            )
          ]
        })

      assert {:error,
              "im_api.internal.send_message accepts only conversation_id, content, request_id, delivery_filter, mentions, reply_to_message_id"} =
               call(agent_id, "internal", "internal.send_message", "internal", %{
                 "conversation_id" => protected_conversation["conversation_id"],
                 "request_id" => "ordinary-clear-protected-refs",
                 "content" => [%{"type" => "text", "text" => "clear protected refs"}],
                 "conversation_update" => %{"source_refs" => %{}}
               })

      assert {:error, {:bad_request, "meeting_activation_refs are product-owned"}} =
               ConversationServer.update_group_conversation(
                 group_id,
                 protected_conversation["conversation_id"],
                 %{"source_refs" => %{}}
               )

      assert {:ok, protected_after_clear} =
               Conversations.get_group_conversation(
                 group_id,
                 protected_conversation["conversation_id"]
               )

      assert protected_after_clear["source_refs"]["meeting_activation_refs"] == inherited_refs

      assert {:ok, %{"message_id" => protected_message_id}} =
               call(agent_id, "internal", "internal.send_message", "internal", %{
                 "conversation_id" => protected_conversation["conversation_id"],
                 "request_id" => "ordinary-message-to-protected-task",
                 "content" => [%{"type" => "text", "text" => "protected result"}]
               })

      assert {:ok, protected_messages} =
               Conversations.list_group_conversation_messages(
                 group_id,
                 protected_conversation["conversation_id"],
                 limit: 20
               )

      protected_message =
        Enum.find(protected_messages, &(&1["message_id"] == protected_message_id))

      assert protected_message["metadata"]["meeting_activation_refs"] == inherited_refs

      protected_source =
        "groupconv:#{protected_conversation["conversation_id"]}:#{protected_message_id}:#{Ids.new_participant_id()}"

      assert {:error, protected_error} =
               call(
                 agent_id,
                 "feishu",
                 "feishu.send_text",
                 feishu_connect_id,
                 %{
                   "receive_id" => "oc_other",
                   "text" => "escaped protected result",
                   "mention_all" => true
                 },
                 %{
                   "tool_context" => %{
                     "source_message_ids" => [protected_source],
                     "source_message_id" => protected_source
                   }
                 }
               )

      assert protected_error =~ "meeting activation is not authorized"

      assert {:ok, _conversation} =
               SalixIM.RouterConversationProjection.get_group_router_conversation(group_id)
    end

    test "ambiguous Feishu provider outcome becomes unknown and is not retried",
         %{
           agent_id: agent_id,
           group_id: group_id,
           feishu_connect_id: connect_id
         } do
      conversation_id = Ids.new_conversation_id()
      message_id = Ids.new_message_id()
      participant_id = Ids.new_participant_id()

      seed_group_conversation(group_id, agent_id, %{"conversation_id" => conversation_id})

      {participant_id, message_id} =
        put_delivery!(group_id, conversation_id, participant_id, %{
          "delivery_id" => "#{group_id}:#{conversation_id}:#{message_id}:#{participant_id}",
          "status" => "pending",
          "agent_group_id" => group_id,
          "conversation_id" => conversation_id,
          "message_id" => message_id,
          "participant_id" => participant_id,
          "participant_actor_type" => "provider",
          "participant_provider" => "feishu",
          "participant_payload" => %{
            "connect_id" => connect_id,
            "chat_id" => "oc_unknown",
            "root_message_id" => "om_unknown_root"
          },
          "operation_ref" => "calendar-notify-unknown",
          "message_content" => [%{"type" => "text", "text" => "Meeting starts now"}],
          "message_created_at" => SystemsClock.system_time(:millisecond)
        })

      MockProviderRuntime.feishu_reply_response(503, %{"message" => "upstream timeout"})

      diagnostic =
        wake_delivery_and_wait!(
          group_id,
          conversation_id,
          participant_id,
          message_id,
          "unknown"
        )

      assert diagnostic["delivery"]["last_error"] =~ "write outcome unknown"
      assert length(MockProviderRuntime.requests(:feishu_reply)) == 1

      assert :ok =
               ConversationServer.wake_participant(group_id, conversation_id, participant_id)

      assert length(MockProviderRuntime.requests(:feishu_reply)) == 1
    end

    test "Router-owned Feishu Task card replies once and follows the Task lifecycle", %{
      tenant: tenant,
      group_id: group_id,
      agent_id: router_id,
      feishu_connect_id: connect_id
    } do
      {conversation_id, worker_id} =
        create_slack_task!(tenant, group_id, router_id, "Build the launch report")

      MockProviderRuntime.feishu_messages([
        %{"message_id" => "om_source", "chat_id" => "oc_task", "msg_type" => "text"}
      ])

      MockProviderRuntime.feishu_reply_response(200, %{
        "code" => 0,
        "msg" => "ok",
        "data" => %{"message_id" => "om_card", "chat_id" => "oc_task"}
      })

      params = %{
        "conversation_id" => conversation_id,
        "chat_id" => "oc_task",
        "message_id" => "om_source"
      }

      assert {:ok, %{"delivery_status" => "queued", "task_id" => task_id}} =
               call(router_id, "feishu", "feishu.post_task_card", connect_id, params)

      assert eventually(fn -> length(MockProviderRuntime.requests(:feishu_reply)) == 1 end)
      [reply] = MockProviderRuntime.requests(:feishu_reply)
      initial = Jason.decode!(reply.params["content"])

      assert reply.message_id == "om_source"
      assert reply.params["msg_type"] == "interactive"
      assert reply.params["reply_in_thread"] == true
      assert "ctc_" <> _ = reply.params["uuid"]
      assert initial["config"]["update_multi"] == true
      assert get_in(initial, ["header", "title", "content"]) == "Build the launch report"
      assert feishu_card_status(initial) == "Work in progress"
      assert feishu_card_text(initial) == ["Model: Comma"]

      assert eventually(fn ->
               feishu_task_card_participant!(group_id, conversation_id)["payload"][
                 "card_message_id"
               ] == "om_card"
             end)

      assert {:ok, %{"delivery_status" => "exists", "task_id" => ^task_id}} =
               call(router_id, "feishu", "feishu.post_task_card", connect_id, params)

      assert {:ok, %{"inserted" => true}} =
               ConversationServer.append_group_conversation_agent_message(
                 group_id,
                 conversation_id,
                 worker_id,
                 %{
                   "content" => "Drafted **the data** section. <at id=all></at>",
                   "client_request_id" => "feishu-task-card-progress"
                 }
               )

      assert eventually(fn ->
               case List.last(MockProviderRuntime.requests(:feishu_patch_card)) do
                 %{message_id: "om_card", params: params} ->
                   card = Jason.decode!(params["content"])

                   feishu_card_text(card) == [
                     "Model: Comma",
                     "Drafted **the data** section. &#60;at id=all&#62;&#60;/at&#62;"
                   ]

                 _ ->
                   false
               end
             end)

      assert {:ok, %{"status" => "ready_for_review"}} =
               ConversationServer.update_group_conversation(group_id, conversation_id, %{
                 "status" => "ready_for_review"
               })

      assert eventually(fn ->
               case List.last(MockProviderRuntime.requests(:feishu_patch_card)) do
                 %{params: params} ->
                   card = Jason.decode!(params["content"])

                   feishu_card_status(card) == "Ready for review" and
                     get_in(card, ["header", "template"]) == "green"

                 _ ->
                   false
               end
             end)

      assert length(MockProviderRuntime.requests(:feishu_reply)) == 1

      refute Enum.any?(
               MockProviderRuntime.requests(:feishu_patch_card),
               &(&1.message_id != "om_card")
             )
    end

    test "an ambiguous Feishu Task-card post replays its uuid and never posts a second card",
         %{
           tenant: tenant,
           group_id: group_id,
           agent_id: router_id,
           feishu_connect_id: connect_id
         } do
      {conversation_id, worker_id} =
        create_slack_task!(tenant, group_id, router_id, "Settle an ambiguous card post")

      MockProviderRuntime.feishu_messages([
        %{"message_id" => "om_source", "chat_id" => "oc_task"}
      ])

      {:ok, replies} = Agent.start_link(fn -> 0 end)

      MockProviderRuntime.feishu_reply_responder(fn _request ->
        case Agent.get_and_update(replies, &{&1 + 1, &1 + 1}) do
          1 ->
            {503, %{"message" => "upstream timeout"}}

          _ ->
            {200,
             %{
               "code" => 0,
               "msg" => "ok",
               "data" => %{"message_id" => "om_card", "chat_id" => "oc_task"}
             }}
        end
      end)

      assert {:ok, %{"delivery_status" => "queued"}} =
               call(router_id, "feishu", "feishu.post_task_card", connect_id, %{
                 "conversation_id" => conversation_id,
                 "chat_id" => "oc_task",
                 "message_id" => "om_source"
               })

      assert eventually(fn ->
               feishu_task_card_participant!(group_id, conversation_id)["payload"][
                 "card_message_id"
               ] == "om_card"
             end)

      [first, replay] = MockProviderRuntime.requests(:feishu_reply)
      assert first.params["uuid"] == replay.params["uuid"]

      assert {:ok, %{"inserted" => true}} =
               ConversationServer.append_group_conversation_agent_message(
                 group_id,
                 conversation_id,
                 worker_id,
                 %{"content" => "Progress after replay.", "client_request_id" => "replayed-card"}
               )

      assert eventually(fn ->
               Enum.any?(MockProviderRuntime.requests(:feishu_patch_card), fn request ->
                 request.message_id == "om_card" and
                   List.last(feishu_card_text(Jason.decode!(request.params["content"]))) ==
                     "Progress after replay."
               end)
             end)

      assert length(MockProviderRuntime.requests(:feishu_reply)) == 2
    end

    test "Feishu Task-card publication rejects a message outside the named chat", %{
      tenant: tenant,
      group_id: group_id,
      agent_id: router_id,
      feishu_connect_id: connect_id
    } do
      {conversation_id, _worker_id} =
        create_slack_task!(tenant, group_id, router_id, "Reject a foreign source")

      MockProviderRuntime.feishu_messages([
        %{"message_id" => "om_elsewhere", "chat_id" => "oc_private"}
      ])

      assert {:error, "message_id does not belong to chat_id"} =
               call(router_id, "feishu", "feishu.post_task_card", connect_id, %{
                 "conversation_id" => conversation_id,
                 "chat_id" => "oc_public",
                 "message_id" => "om_elsewhere"
               })

      assert {:ok, %{"participants" => participants}} =
               Conversations.list_group_conversation_participants(group_id, conversation_id)

      refute Enum.any?(participants, &(&1["provider"] == "feishu"))
      assert MockProviderRuntime.requests(:feishu_reply) == []
    end

    test "Router reassignment immediately revokes the old Router's Feishu connect",
         %{
           tenant: tenant,
           group_id: group_id,
           agent_id: old_router_id,
           feishu_connect_id: connect_id
         } do
      {:ok, new_router} =
        create_control_agent(
          %{"name" => "New Router", "group_id" => group_id, "role" => "router"},
          tenant
        )

      {:ok, _group} =
        SalixStore.CasRecord.update(Keys.ctl_group(group_id), fn group ->
          Map.put(group, "router_agent_id", new_router["agent_id"])
        end)

      assert {:error, "connect not found"} =
               call(old_router_id, "feishu", "feishu.get_chat_history", connect_id, %{
                 "chat_id" => "oc_revoked"
               })

      assert {:ok, %{"messages" => []}} =
               call(new_router["agent_id"], "feishu", "feishu.get_chat_history", connect_id, %{
                 "chat_id" => "oc_current"
               })

      [request] = MockProviderRuntime.requests(:feishu_list_messages)
      assert request.query["container_id"] == "oc_current"
    end

    test "does not read arbitrary host paths", %{
      agent_id: agent_id,
      feishu_connect_id: connect_id
    } do
      seed_agent_vfs(agent_id, %{})
      host_path = host_file!("HOST-SECRET-FEISHU")

      assert {:error, message} =
               call(agent_id, "feishu", "feishu.send_file", connect_id, %{
                 "receive_id" => "oc_1",
                 "path" => host_path
               })

      assert message =~ "file not found in agent VFS"
      assert MockProviderRuntime.requests(:feishu_validate) == []
      assert MockProviderRuntime.requests(:feishu_image_upload) == []
      assert MockProviderRuntime.requests(:feishu_file_upload) == []
      assert MockProviderRuntime.requests(:feishu_message) == []
    end

    test "send_image uploads bytes through image endpoint and sends returned image key", %{
      agent_id: agent_id,
      feishu_connect_id: connect_id
    } do
      seed_agent_vfs(agent_id, %{"/attachments/pic.png" => @png})

      assert {:ok, %{"message_id" => "om_sent"}} =
               call(agent_id, "feishu", "feishu.send_image", connect_id, %{
                 "receive_id" => "oc_1",
                 "path" => "/attachments/pic.png"
               })

      [upload] = MockProviderRuntime.requests(:feishu_image_upload)
      assert upload.auth == "Bearer tenant-token-cli_media"
      assert upload.raw =~ "vfs-image-bytes"
      assert upload.raw =~ ~s(filename="pic.png")
      assert upload.raw =~ ~s(name="image_type")
      assert upload.raw =~ "message"
      assert MockProviderRuntime.requests(:feishu_file_upload) == []

      [message] = MockProviderRuntime.requests(:feishu_message)
      assert message.query["receive_id_type"] == "chat_id"
      assert message.params["receive_id"] == "oc_1"
      assert message.params["msg_type"] == "image"
      assert Jason.decode!(message.params["content"]) == %{"image_key" => "image-key-1"}
    end

    test "explicit text escapes literal at-tags so only structured mentions can notify", %{
      agent_id: agent_id,
      feishu_connect_id: connect_id
    } do
      assert {:ok, %{"message_id" => "om_sent"}} =
               call(agent_id, "feishu", "feishu.send_text", connect_id, %{
                 "receive_id" => "oc_1",
                 "text" => ~s(<at user_id="all">all</at> & <AT user_id="ou_eve">Eve</AT>),
                 "format" => "text",
                 "mentions" => [%{"user_id" => "ou_alice", "name" => "Alice"}],
                 "mention_all" => false
               })

      [message] = MockProviderRuntime.requests(:feishu_message)
      text = message.params["content"] |> Jason.decode!() |> Map.fetch!("text")

      assert String.starts_with?(text, ~s(<at user_id="ou_alice">Alice</at> ))
      assert text =~ ~s(&lt;at user_id=&quot;all&quot;&gt;all&lt;/at&gt;)
      assert text =~ ~s(&lt;AT user_id=&quot;ou_eve&quot;&gt;Eve&lt;/AT&gt;)
      refute text =~ ~s(<at user_id="all">)
    end

    test "chat history is one Slack-like page and one resource streams to VFS", %{
      agent_id: agent_id,
      feishu_connect_id: connect_id
    } do
      file_message = %{
        "message_id" => "om_budget",
        "chat_id" => "oc_1",
        "msg_type" => "file",
        "create_time" => "1784000000",
        "sender" => %{"id" => "ou_sender", "sender_type" => "user"},
        "body" => %{
          "content" => Jason.encode!(%{"file_key" => "file-budget", "file_name" => "预算表.xlsx"})
        }
      }

      MockProviderRuntime.feishu_messages([file_message])

      MockProviderRuntime.feishu_message_responder(fn _query ->
        %{
          "items" => [file_message],
          "has_more" => true,
          "page_token" => "next-feishu-page"
        }
      end)

      MockProviderRuntime.feishu_resource("application/vnd.ms-excel", "BUDGET-BYTES")

      assert {:ok, page} =
               call(agent_id, "feishu", "feishu.get_chat_history", connect_id, %{
                 "chat_id" => "oc_1",
                 "page_size" => 500,
                 "start_time" => "1784000000"
               })

      assert page["has_more"]
      assert page["next_page_token"] == "next-feishu-page"

      assert [
               %{
                 "message_id" => "om_budget",
                 "attachments" => [attachment]
               }
             ] = page["messages"]

      assert attachment["file_key"] == "file-budget"
      assert attachment["resource_type"] == "file"
      assert attachment["file_name"] == "预算表.xlsx"
      assert String.starts_with?(attachment["resource_ref"], "fr2.")

      [history_request] = MockProviderRuntime.requests(:feishu_list_messages)

      assert history_request.query["container_id_type"] == "chat"
      assert history_request.query["container_id"] == "oc_1"
      assert history_request.query["page_size"] == "50"
      assert history_request.query["start_time"] == "1784000000"
      assert history_request.query["with_sender_name"] == "true"
      assert history_request.query["card_msg_content_type"] == "raw_card_content"
      assert history_request.query["only_thread_root_messages"] == "true"

      assert {:ok, files_page} =
               call(agent_id, "feishu", "feishu.list_chat_files", connect_id, %{
                 "chat_id" => "oc_1"
               })

      assert files_page["messages_scanned"] == 1

      files_requests = MockProviderRuntime.requests(:feishu_list_messages)
      files_request = Enum.at(files_requests, 1)
      assert files_request.query["page_size"] == "50"
      assert files_request.query["only_thread_root_messages"] == "true"

      assert [
               %{
                 "message_id" => "om_budget",
                 "file_key" => "file-budget",
                 "resource_ref" => resource_ref
               }
             ] = files_page["files"]

      assert resource_ref == attachment["resource_ref"]

      assert {:ok, staged} =
               call(agent_id, "feishu", "feishu.fetch_message_resource", connect_id, %{
                 "resource_ref" => resource_ref
               })

      assert staged["file_name"] == "预算表.xlsx"
      assert staged["mime_type"] == "application/vnd.ms-excel"
      assert staged["size"] == byte_size("BUDGET-BYTES")
      assert String.starts_with?(staged["vfs_path"], "/feishu/files/")

      assert {:ok, %{data: "BUDGET-BYTES"}} =
               SalixIM.Ports.AgentWorkspace.read_upload(agent_id, staged["vfs_path"])

      [resource_request] = MockProviderRuntime.requests(:feishu_message_resource)
      assert resource_request.message_id == "om_budget"
      assert resource_request.file_key == "file-budget"
      assert resource_request.query["type"] == "file"
    end

    test "a Feishu resource ref listed by one connect is rejected by another before IO", %{
      tenant: tenant,
      group_id: group_id,
      agent_id: agent_id,
      feishu_connect_id: connect_id
    } do
      other_connect_id = "fs-media-other"

      seed_connect(group_id, other_connect_id, "feishu", %{
        "tenant_id" => tenant,
        "status" => "connected",
        "app_id" => "cli_media"
      })

      file_message = %{
        "message_id" => "om_connect_bound",
        "chat_id" => "oc_1",
        "msg_type" => "file",
        "body" => %{
          "content" =>
            Jason.encode!(%{
              "file_key" => "file-connect-bound",
              "file_name" => "connect-bound.txt"
            })
        }
      }

      MockProviderRuntime.feishu_message_responder(fn _query ->
        %{"items" => [file_message], "has_more" => false, "page_token" => ""}
      end)

      assert {:ok, %{"files" => [%{"resource_ref" => resource_ref}]}} =
               call(agent_id, "feishu", "feishu.list_chat_files", connect_id, %{
                 "chat_id" => "oc_1"
               })

      assert {:error, reason} =
               call(agent_id, "feishu", "feishu.fetch_message_resource", other_connect_id, %{
                 "resource_ref" => resource_ref
               })

      assert reason =~ "invalid Feishu resource_ref"
      assert MockProviderRuntime.requests(:feishu_get_message) == []
      assert MockProviderRuntime.requests(:feishu_message_resource) == []
    end

    test "group-member and directory tools stay explicit and paginated", %{
      agent_id: agent_id,
      feishu_connect_id: connect_id
    } do
      assert {:ok, %{"members" => [%{"member_id" => "ou_alice"}]}} =
               call(agent_id, "feishu", "feishu.list_chat_members", connect_id, %{
                 "chat_id" => "oc_1"
               })

      assert {:ok,
              %{
                "departments" => [
                  %{"open_department_id" => "od_engineering", "name" => "Engineering"}
                ]
              }} =
               call(agent_id, "feishu", "feishu.list_departments", connect_id, %{})

      assert {:ok, %{"users" => [%{"open_id" => "ou_alice", "name" => "Alice"}]}} =
               call(agent_id, "feishu", "feishu.list_department_users", connect_id, %{
                 "department_id" => "od_engineering"
               })

      assert {:ok, %{"user" => %{"open_id" => "ou_alice", "name" => "Alice"}}} =
               call(agent_id, "feishu", "feishu.get_user", connect_id, %{
                 "user_id" => "ou_alice"
               })

      assert {:ok,
              %{
                "department_ids" => ["od_engineering"],
                "user_ids" => ["ou_explicit"],
                "group_ids" => ["ug_oncall"],
                "has_more" => true,
                "next_page_token" => "contact-scope-page-2"
              }} =
               call(agent_id, "feishu", "feishu.list_contact_scopes", connect_id, %{})

      [member_request] = MockProviderRuntime.requests(:feishu_list_chat_members)
      assert member_request.query["member_id_type"] == "open_id"

      [department_request] = MockProviderRuntime.requests(:feishu_list_departments)
      assert department_request.department_id == "0"
      assert department_request.query["fetch_child"] == "false"

      [directory_request] = MockProviderRuntime.requests(:feishu_list_department_users)
      assert directory_request.query["department_id"] == "od_engineering"
      assert directory_request.query["user_id_type"] == "open_id"

      [scope_request] = MockProviderRuntime.requests(:feishu_list_contact_scopes)
      assert scope_request.query["page_size"] == "100"
      assert scope_request.query["user_id_type"] == "open_id"
      assert scope_request.query["department_id_type"] == "open_department_id"
      assert length(MockProviderRuntime.requests(:feishu_validate)) == 1
    end

    test "tenant token acquisition safely retries and caches the result", %{
      agent_id: agent_id,
      feishu_connect_id: connect_id
    } do
      MockProviderRuntime.feishu_token_responses([
        {503, %{"code" => 50_000, "msg" => "temporary auth outage"}},
        {200,
         %{
           "code" => 0,
           "msg" => "ok",
           "expire" => 7_200,
           "tenant_access_token" => "tenant-token-after-retry"
         }}
      ])

      assert {:ok, %{"members" => [_]}} =
               call(agent_id, "feishu", "feishu.list_chat_members", connect_id, %{
                 "chat_id" => "oc_1"
               })

      assert {:ok, %{"departments" => [_]}} =
               call(agent_id, "feishu", "feishu.list_departments", connect_id, %{})

      assert length(MockProviderRuntime.requests(:feishu_validate)) == 2
    end

    # Both Feishu tenant-token rejection codes take the one-refresh path.
    for {kind, rejection_code, message_id, file_key, bytes} <- [
          {"an expired", nil, "om_refresh_resource", "file-refresh", "REFRESHED"},
          {"an invalid", 99_991_665, "om_invalid_tenant_resource", "file-invalid-tenant",
           "RECOVERED"}
        ] do
      @bytes bytes
    end

    test "write UUIDs are deterministic per tool call and operation", %{
      agent_id: agent_id,
      feishu_connect_id: connect_id
    } do
      params = %{"receive_id" => "oc_uuid", "text" => "idempotent delivery"}

      for tool_call_id <- ["tool-same", "tool-same", "tool-different"] do
        assert {:ok, _} =
                 call(
                   agent_id,
                   "feishu",
                   "feishu.send_text",
                   connect_id,
                   params,
                   %{"tool_call_id" => tool_call_id}
                 )
      end

      [first, second, third] = MockProviderRuntime.requests(:feishu_message)
      assert first.params["uuid"] == second.params["uuid"]
      refute first.params["uuid"] == third.params["uuid"]
      assert String.starts_with?(first.params["uuid"], "bft_")

      for _ <- 1..2 do
        assert {:ok, _} =
                 call(
                   agent_id,
                   "feishu",
                   "feishu.reply_text",
                   connect_id,
                   %{"message_id" => "om_uuid", "text" => "same reply"},
                   %{"tool_call_id" => "reply-same"}
                 )
      end

      [reply_first, reply_second] = MockProviderRuntime.requests(:feishu_reply)
      assert reply_first.params["uuid"] == reply_second.params["uuid"]
      refute reply_first.params["uuid"] == first.params["uuid"]
    end

    test "bot-owned message, reaction, and Pin mutations enforce and call bounded APIs", %{
      agent_id: agent_id,
      feishu_connect_id: connect_id
    } do
      MockProviderRuntime.feishu_messages([
        %{
          "message_id" => "om_bot",
          "chat_id" => "oc_1",
          "msg_type" => "text",
          "sender" => %{"id" => "cli_media", "sender_type" => "app"},
          "body" => %{"content" => Jason.encode!(%{"text" => "before"})}
        },
        %{
          "message_id" => "om_human",
          "chat_id" => "oc_1",
          "msg_type" => "text",
          "sender" => %{"id" => "ou_human", "sender_type" => "user"},
          "body" => %{"content" => Jason.encode!(%{"text" => "human"})}
        }
      ])

      assert {:ok, _} =
               call(agent_id, "feishu", "feishu.update_message", connect_id, %{
                 "message_id" => "om_bot",
                 "text" => ~s(after <at user_id="all">all</at>)
               })

      assert {:ok, _} =
               call(agent_id, "feishu", "feishu.delete_message", connect_id, %{
                 "message_id" => "om_bot"
               })

      assert {:error, message} =
               call(agent_id, "feishu", "feishu.delete_message", connect_id, %{
                 "message_id" => "om_human"
               })

      assert message =~ "not authored by this bot"

      [update] = MockProviderRuntime.requests(:feishu_update_message)
      assert update.message_id == "om_bot"

      assert update.params["msg_type"] == "post"

      assert SalixIM.Provider.Feishu.Message.text(update.params) ==
               ~S(after \<at user\_id="all"\>all\</at\>)

      assert [%{message_id: "om_bot"}] = MockProviderRuntime.requests(:feishu_delete_message)

      MockProviderRuntime.feishu_reactions([
        %{
          "reaction_id" => "reaction-bot",
          "operator" => %{"operator_type" => "app", "operator_id" => "cli_media"},
          "reaction_type" => %{"emoji_type" => "SMILE"}
        }
      ])

      assert {:ok, _} =
               call(agent_id, "feishu", "feishu.add_reaction", connect_id, %{
                 "message_id" => "om_human",
                 "emoji_type" => "SMILE"
               })

      assert {:ok, %{"reactions" => [_]}} =
               call(agent_id, "feishu", "feishu.list_reactions", connect_id, %{
                 "message_id" => "om_human",
                 "page_size" => 100
               })

      assert {:ok, _} =
               call(agent_id, "feishu", "feishu.remove_reaction", connect_id, %{
                 "message_id" => "om_human",
                 "reaction_id" => "reaction-bot"
               })

      assert {:ok, _} =
               call(agent_id, "feishu", "feishu.pin_message", connect_id, %{
                 "message_id" => "om_human"
               })

      assert {:ok, %{"pins" => [%{"message_id" => "om_pin"}]}} =
               call(agent_id, "feishu", "feishu.list_pins", connect_id, %{
                 "chat_id" => "oc_1"
               })

      assert {:ok, _} =
               call(agent_id, "feishu", "feishu.unpin_message", connect_id, %{
                 "message_id" => "om_human"
               })

      assert [%{reaction_id: "reaction-bot"}] =
               MockProviderRuntime.requests(:feishu_remove_reaction)

      assert [%{params: %{"message_id" => "om_human"}}] =
               MockProviderRuntime.requests(:feishu_pin)

      assert [%{message_id: "om_human"}] = MockProviderRuntime.requests(:feishu_unpin)
    end

    test "thread replies request Feishu thread creation and persist bot participation", %{
      agent_id: agent_id,
      feishu_connect_id: connect_id
    } do
      assert {:ok, %{"message_id" => "om_reply_sent"}} =
               call(agent_id, "feishu", "feishu.reply_text", connect_id, %{
                 "message_id" => "om_top_level",
                 "chat_id" => "oc_thread",
                 "reply_in_thread" => true,
                 "text" => "thread reply"
               })

      [request] = MockProviderRuntime.requests(:feishu_reply)
      assert request.params["reply_in_thread"] == true

      assert {:ok, connect} = SalixIM.ProviderConnects.find_active_im_connect_by_id(connect_id)

      assert SalixIM.ProviderConnects.feishu_thread_participating?(
               connect,
               "oc_thread",
               "omt_thread"
             )
    end
  end

  # ---- internal delivery ----

  describe "call_api/4 internal" do
    test "im_api.internal.add_agent_participant owns Router-scoped participant mutation",
         %{tenant: tenant, group_id: group_id, agent_id: agent_id} do
      {:ok, worker} =
        create_control_agent(
          %{"name" => "Participant worker", "group_id" => group_id, "role" => "worker"},
          tenant
        )

      conversation = seed_group_conversation(group_id, agent_id, %{})

      params = %{
        "conversation_id" => conversation["conversation_id"],
        "agent_id" => worker["agent_id"],
        "role_label" => "researcher",
        "notification_filter" => %{"messages" => "mentioned", "statuses" => "none"}
      }

      assert {:ok, participant} =
               call(
                 agent_id,
                 "internal",
                 "internal.add_agent_participant",
                 "internal",
                 params
               )

      assert participant["conversation_id"] == conversation["conversation_id"]
      assert participant["agent_id"] == worker["agent_id"]
      assert participant["role_label"] == "researcher"
      assert participant["state"] == "active"
      assert Ids.valid_participant_id?(participant["participant_id"])

      assert participant["notification_filter"] == %{
               "messages" => "mentioned",
               "statuses" => "none"
             }

      assert {:ok, retry} =
               call(
                 agent_id,
                 "internal",
                 "internal.add_agent_participant",
                 "internal",
                 params
               )

      assert retry == participant

      assert {:error, "notification_filter.statuses must be none for Agent participants"} =
               call(
                 agent_id,
                 "internal",
                 "internal.add_agent_participant",
                 "internal",
                 put_in(params, ["notification_filter", "statuses"], "all")
               )

      assert {:error, "notification_filter must be an object"} =
               call(
                 agent_id,
                 "internal",
                 "internal.add_agent_participant",
                 "internal",
                 Map.put(params, "notification_filter", false)
               )

      default_conversation = seed_group_conversation(group_id, agent_id, %{})

      assert {:ok, default_participant} =
               call(
                 agent_id,
                 "internal",
                 "internal.add_agent_participant",
                 "internal",
                 %{
                   "conversation_id" => default_conversation["conversation_id"],
                   "agent_id" => worker["agent_id"]
                 }
               )

      assert default_participant["notification_filter"] == %{
               "messages" => "all",
               "statuses" => "none"
             }

      assert {:error, "operation is not authorized for this agent role"} =
               call(
                 worker["agent_id"],
                 "internal",
                 "internal.add_agent_participant",
                 "internal",
                 params
               )

      assert {:error, "params must be a JSON object"} =
               call(
                 agent_id,
                 "internal",
                 "internal.add_agent_participant",
                 "internal",
                 "invalid"
               )

      other_group_id = Ids.new_group_id(tenant)
      SalixAgent.TestSupport.create_control_group!(other_group_id, %{"name" => "Other group"})

      other_worker =
        SalixAgent.TestSupport.create_control_agent_in_group!(tenant, other_group_id, %{
          "name" => "Other worker",
          "role" => "worker"
        })

      assert {:error, cross_group_error} =
               call(
                 agent_id,
                 "internal",
                 "internal.add_agent_participant",
                 "internal",
                 Map.put(params, "agent_id", other_worker["agent_id"])
               )

      assert cross_group_error =~ "not_found"

      for bad_params <- [
            Map.put(params, "agent_id", Ids.new_agent_id(group_id)),
            Map.put(params, "conversation_id", Ids.new_conversation_id())
          ] do
        assert {:error, error} =
                 call(
                   agent_id,
                   "internal",
                   "internal.add_agent_participant",
                   "internal",
                   bad_params
                 )

        assert error =~ "not_found"
      end
    end

    test "im_api.internal.task.create owns command preparation and calls only the TaskSchedules port",
         %{
           tenant: tenant,
           group_id: group_id,
           agent_id: agent_id
         } do
      previous = SystemsRuntime.get_env(:salix_im, :task_create_mod)
      SystemsRuntime.put_env(:salix_im, :task_create_mod, RecordingTaskCreate)
      RecordingTaskCreate.set_owner(SystemsRuntime.Proc.self())

      on_exit(fn -> restore(:salix_im, :task_create_mod, previous) end)

      source_conversation =
        seed_group_conversation(group_id, agent_id, %{
          "messages" => [
            %{
              "content" => "Create a delegated artifact.",
              "source_message_id" => "task-create-source"
            }
          ]
        })

      conversation_id = source_conversation["conversation_id"]

      assert {:ok, [source_message]} =
               Conversations.list_group_conversation_messages(group_id, conversation_id,
                 limit: 10
               )

      message_id = source_message["message_id"]
      participant_id = Ids.new_participant_id()

      trusted_origin = %{
        "provider" => "internal",
        "conversation_id" => conversation_id,
        "conversation_kind" => "user_chat",
        "message_id" => message_id,
        "participant_id" => participant_id,
        "agent_group_id" => group_id
      }

      source_message_id =
        Enum.join(["groupconv", conversation_id, message_id, participant_id], ":")

      {:ok, worker} =
        create_control_agent(
          %{"name" => "Create target", "group_id" => group_id, "role" => "worker"},
          tenant
        )

      params = %{
        "agent_id" => worker["agent_id"],
        "content" => "  Create the requested artifact.  ",
        "title" => "  Requested artifact  ",
        "parent_conversation_id" => Ids.new_conversation_id(),
        "parent_message_id" => Ids.new_message_id()
      }

      metadata = %{
        "tool_call_id" => "create-call-1",
        "tool_context" => %{
          "session_id" => "ses1_task_create",
          "runtime_kind" => "external",
          "role" => "worker",
          "group_id" => "forged-group",
          "source_message_id" => source_message_id,
          "source_message_ids" => [source_message_id],
          "trusted_origin" => trusted_origin
        }
      }

      assert {:ok,
              %{
                "created" => true,
                "conversation_id" => created_id,
                "conversation_kind" => "agent_task",
                "agent_id" => target_agent_id,
                "message_id" => created_message_id,
                "delivery_status" => "queued",
                "inserted" => true,
                "sent" => true,
                "status" => "active",
                "title" => "  Requested artifact  "
              }} =
               call(agent_id, "internal", "internal.task.create", "internal", params, metadata)

      assert Ids.valid_conversation_id?(created_id)
      assert Ids.valid_message_id?(created_message_id)
      assert target_agent_id == worker["agent_id"]

      settle_receive({:task_create, ^group_id, ^agent_id, ^target_agent_id, attrs})
      assert attrs["content"] == "  Create the requested artifact.  "
      assert attrs["title"] == "  Requested artifact  "
      assert attrs["schedule"] == nil
      assert attrs["origin_session_id"] == "ses1_task_create"
      assert attrs["source_refs"]["origin_agent_id"] == agent_id
      assert attrs["source_refs"]["parent_conversation_id"] == conversation_id
      assert attrs["source_refs"]["parent_message_id"] == message_id
      assert attrs["source_refs"]["origin_session_id"] == "ses1_task_create"

      for {requester, members} <- [
            {"system", []},
            {"provider_user|cnx1|U_A", ["provider_user|cnx1|U_A"]}
          ] do
        labelled_metadata =
          put_in(metadata, ["tool_context", "ifc_evidence"], %{
            "requester" => requester,
            "sources_label" => ["scope|cnx1|C_PRIVATE"]
          })

        assert {:ok, _} =
                 call(
                   agent_id,
                   "internal",
                   "internal.task.create",
                   "internal",
                   params,
                   labelled_metadata
                 )

        settle_receive({:task_create, ^group_id, ^agent_id, ^target_agent_id, labelled_attrs})
        assert labelled_attrs["source_refs"]["ifc_members"] == members
        assert labelled_attrs["source_refs"]["ifc_provenance"] == ["scope|cnx1|C_PRIVATE"]
      end

      refute attrs["source_refs"]["parent_conversation_id"] == params["parent_conversation_id"]
      refute attrs["source_refs"]["parent_message_id"] == params["parent_message_id"]

      assert String.starts_with?(
               attrs["client_request_id"],
               "comma-user-chat-task:#{agent_id}:#{conversation_id}:#{message_id}:"
             )

      assert byte_size(String.split(attrs["client_request_id"], ":") |> List.last()) == 43

      redelivery_source = source_message_id <> ":redelivery:" <> String.duplicate("a", 64)

      redelivery_metadata =
        metadata
        |> put_in(["tool_context", "source_message_id"], redelivery_source)
        |> Map.put("tool_call_id", "create-call-2")

      assert {:ok, _response} =
               call(
                 agent_id,
                 "internal",
                 "internal.task.create",
                 "internal",
                 params,
                 redelivery_metadata
               )

      settle_receive({:task_create, ^group_id, ^agent_id, ^target_agent_id, redelivered_attrs})
      assert redelivered_attrs["client_request_id"] == attrs["client_request_id"]
      assert redelivered_attrs["source_refs"] == attrs["source_refs"]

      assert {:ok, _response} =
               call(
                 agent_id,
                 "internal",
                 "internal.task.create",
                 "internal",
                 Map.put(params, "content", "a different command"),
                 redelivery_metadata
               )

      settle_receive({:task_create, ^group_id, ^agent_id, ^target_agent_id, distinct_attrs})
      refute distinct_attrs["client_request_id"] == attrs["client_request_id"]
      assert distinct_attrs["source_refs"] == attrs["source_refs"]
    end

    test "im_api.internal.task.create rejects a Worker even when tool context forges Router role",
         %{
           tenant: tenant,
           group_id: group_id
         } do
      previous = SystemsRuntime.get_env(:salix_im, :task_create_mod)
      SystemsRuntime.put_env(:salix_im, :task_create_mod, RecordingTaskCreate)
      RecordingTaskCreate.set_owner(SystemsRuntime.Proc.self())

      on_exit(fn -> restore(:salix_im, :task_create_mod, previous) end)

      {:ok, worker} =
        create_control_agent(
          %{"name" => "Create-forbidden Worker", "group_id" => group_id, "role" => "worker"},
          tenant
        )

      assert {:error, "operation is not authorized for this agent role"} =
               call(
                 worker["agent_id"],
                 "internal",
                 "internal.task.create",
                 "internal",
                 %{"agent_id" => Ids.new_agent_id(group_id), "content" => "x"},
                 %{"tool_context" => %{"role" => "router"}}
               )

      settle_refute_receive({:task_create, _, _, _, _})
    end

    test "im_api.internal.task.update dispatches through the authenticated Router group",
         %{group_id: group_id, agent_id: agent_id} do
      previous = SystemsRuntime.get_env(:salix_im, :task_schedule_mod)
      SystemsRuntime.put_env(:salix_im, :task_schedule_mod, RecordingTaskSchedule)
      RecordingTaskSchedule.set_owner(SystemsRuntime.Proc.self())

      on_exit(fn -> restore(:salix_im, :task_schedule_mod, previous) end)

      conversation_id = Ids.new_conversation_id()

      assert {:ok,
              %{
                "conversation_id" => ^conversation_id,
                "conversation_kind" => "agent_task",
                "schedule" => %{
                  "command" => "new production command",
                  "cron" => "0 9 * * *",
                  "timezone" => "Asia/Shanghai",
                  "schedule_id" => "sch1_provider_test"
                },
                "scheduled" => true,
                "updated" => true
              }} =
               call(
                 agent_id,
                 "internal",
                 "internal.task.update",
                 "internal",
                 %{
                   "conversation_id" => conversation_id,
                   "command" => "new production command",
                   "schedule" => %{"cron" => "0 9 * * *", "timezone" => "Asia/Shanghai"}
                 },
                 %{"tool_context" => %{"role" => "worker", "group_id" => "forged-group"}}
               )

      settle_receive(
        {:task_schedule_update, ^group_id, ^conversation_id,
         %{
           "command" => "new production command",
           "cron" => "0 9 * * *",
           "timezone" => "Asia/Shanghai"
         }}
      )

      assert {:error,
              "im_api.internal.task.update accepts only conversation_id, command, schedule"} =
               call(agent_id, "internal", "internal.task.update", "internal", %{
                 "conversation_id" => conversation_id,
                 "extra" => true
               })

      for {params, expected} <- [
            {%{"conversation_id" => conversation_id}, "provide command and/or schedule"},
            {%{"conversation_id" => conversation_id, "command" => "  "},
             "command must be complete command text"},
            {%{"conversation_id" => conversation_id, "schedule" => "daily"},
             "schedule must be an object or null"},
            {%{"conversation_id" => conversation_id, "command" => "x", "schedule" => nil},
             "command cannot be changed while removing schedule"},
            {%{"conversation_id" => conversation_id, "schedule" => %{"cron" => "0 9 * * *"}},
             "schedule.timezone is required with schedule.cron; ask the user if it is unclear"},
            {%{
               "conversation_id" => conversation_id,
               "schedule" => %{
                 "cron" => "0 9 * * *",
                 "timezone" => "UTC",
                 "interval_minutes" => 5
               }
             }, "provide exactly one of schedule.interval_minutes or schedule.cron"}
          ] do
        assert {:error, ^expected} =
                 call(agent_id, "internal", "internal.task.update", "internal", params)
      end

      assert {:ok, %{"scheduled" => false, "schedule" => %{"schedule_id" => nil}}} =
               call(agent_id, "internal", "internal.task.update", "internal", %{
                 "conversation_id" => conversation_id,
                 "schedule" => nil
               })

      settle_receive({:task_schedule_update, ^group_id, ^conversation_id, nil})
    end

    test "im_api.internal.task.list returns a bounded multi-kind projection with kind-correct refs",
         %{
           group_id: group_id,
           agent_id: agent_id
         } do
      chat =
        seed_group_conversation(group_id, agent_id, %{
          "kind" => "user_chat",
          "title" => "Ordinary internal chat",
          "source_refs" => %{"private" => "must not escape"},
          "parent_conversation_id" => Ids.new_conversation_id()
        })

      task =
        seed_group_conversation(group_id, agent_id, %{
          "kind" => "agent_task",
          "title" => "Typed Task"
        })

      assert {:ok,
              %{
                "tasks" => tasks,
                "count" => count,
                "has_more" => false,
                "next_action" => next_action
              } = result} =
               call(agent_id, "internal", "internal.task.list", "internal", %{})

      assert count == length(tasks)
      refute Map.has_key?(result, "next_cursor")
      # The guidance must name the projected field and the tool that acts on it.
      assert next_action =~ "task_ref"
      assert next_action =~ "im_api.internal.send_message"

      by_id = Map.new(tasks, &{&1["task_id"], &1})

      assert %{
               "task_id" => task_id,
               "kind" => "agent_task",
               "title" => "Typed Task",
               "status" => "active",
               "activity_status" => "idle",
               "created_at" => created_at,
               "updated_at" => updated_at,
               "task_ref" => %{
                 "type" => "conversation_ref",
                 "conversation_id" => task_id,
                 "kind" => "agent_task",
                 "presentation" => "inline"
               }
             } = by_id[task["conversation_id"]]

      assert is_integer(created_at)
      assert is_integer(updated_at)

      assert %{
               "task_id" => chat_id,
               "kind" => "user_chat",
               "title" => "Ordinary internal chat",
               "task_ref" => %{
                 "type" => "conversation_ref",
                 "conversation_id" => chat_id,
                 "kind" => "user_chat"
               }
             } = by_id[chat["conversation_id"]]

      refute Map.has_key?(by_id[chat["conversation_id"]]["task_ref"], "presentation")

      for entry <- tasks do
        assert Map.keys(entry) |> Enum.sort() ==
                 ~w(activity_status created_at kind status task_id task_ref title updated_at)

        refute Map.has_key?(entry, "conversation_id")
        refute Map.has_key?(entry, "source_refs")
        refute Map.has_key?(entry, "parent_conversation_id")
      end
    end

    test "im_api.internal.task.list rejects Workers and strict-schema violations from direct provider calls",
         %{
           tenant: tenant,
           group_id: group_id,
           agent_id: agent_id
         } do
      {:ok, worker} =
        create_control_agent(
          %{"name" => "List-forbidden Worker", "group_id" => group_id, "role" => "worker"},
          tenant
        )

      assert {:error, "operation is not authorized for this agent role"} =
               call(
                 worker["agent_id"],
                 "internal",
                 "internal.task.list",
                 "internal",
                 %{},
                 %{"tool_context" => %{"role" => "router", "agent" => %{"role" => "router"}}}
               )

      assert {:error, "im_api.internal.task.list accepts only cursor and limit"} =
               call(agent_id, "internal", "internal.task.list", "internal", %{
                 "query" => "no title filter"
               })

      assert {:error, "limit must be an integer between 1 and 1000"} =
               call(agent_id, "internal", "internal.task.list", "internal", %{"limit" => 1001})

      assert {:error, "limit must be an integer between 1 and 1000"} =
               call(agent_id, "internal", "internal.task.list", "internal", %{"limit" => "1"})

      assert {:error, "cursor must be a non-empty string of at most 1024 characters"} =
               call(agent_id, "internal", "internal.task.list", "internal", %{"cursor" => ""})

      assert {:error, ":invalid_cursor"} =
               call(agent_id, "internal", "internal.task.list", "internal", %{
                 "cursor" => "not-a-conversation-cursor"
               })
    end

    test "an explicit committed Message is archived once, excluding retries and failures",
         %{group_id: group_id, agent_id: agent_id} do
      previous_provider = SystemsRuntime.get_env(:salix_agent, :im_provider_mod)
      previous_archive = SystemsRuntime.get_env(:salix_agent, :event_archive_mod)
      previous_owner = SystemsRuntime.get_env(:salix_im, :event_archive_test_pid)

      SystemsRuntime.put_env(:salix_agent, :im_provider_mod, SalixIM.Provider)
      SystemsRuntime.put_env(:salix_agent, :event_archive_mod, EventArchiveRecorder)
      SystemsRuntime.put_env(:salix_im, :event_archive_test_pid, SystemsRuntime.Proc.self())

      on_exit(fn ->
        restore(:salix_agent, :im_provider_mod, previous_provider)
        restore(:salix_agent, :event_archive_mod, previous_archive)
        restore(:salix_im, :event_archive_test_pid, previous_owner)
      end)

      conversation =
        seed_group_conversation(group_id, agent_id, %{"title" => "Archived explicit send"})

      params = %{
        "connect_id" => "internal",
        "conversation_id" => conversation["conversation_id"],
        "request_id" => "archived-explicit-send",
        "content" => [%{"type" => "text", "text" => "A committed visible Message"}]
      }

      ctx = internal_send_context(agent_id, group_id, "archive-send-1")

      first =
        "im_api.internal.send_message"
        |> SalixAgent.Tools.ImRouter.call_dynamic_operation(params, ctx)
        |> Jason.decode!()

      assert first["inserted"] == true

      settle_receive(
        {:archived,
         %{
           boundary: :egress,
           direction: :out,
           agent_id: ^agent_id,
           session_id: "archive-session",
           payload: %{
             "method" => "im_api.internal.send_message",
             "connect_id" => "internal",
             "params" => ^params,
             "result" => %{
               "conversation_id" => conversation_id,
               "message_id" => message_id,
               "inserted" => true
             }
           }
         }}
      )

      assert conversation_id == conversation["conversation_id"]
      assert message_id == first["message_id"]

      replay =
        "im_api.internal.send_message"
        |> SalixAgent.Tools.ImRouter.call_dynamic_operation(params, ctx)
        |> Jason.decode!()

      assert replay["message_id"] == message_id
      assert replay["inserted"] == false
      settle_refute_receive({:archived, %{boundary: :egress}}, 100)

      missing_params = %{
        "connect_id" => "internal",
        "conversation_id" => Ids.new_conversation_id(),
        "request_id" => "failed-explicit-send",
        "content" => [%{"type" => "text", "text" => "Must not be archived"}]
      }

      assert_raise RuntimeError, "conversation not found", fn ->
        SalixAgent.Tools.ImRouter.call_dynamic_operation(
          "im_api.internal.send_message",
          missing_params,
          ctx
        )
      end

      settle_refute_receive({:archived, %{boundary: :egress}}, 100)

      assert {:ok, [%{"message_id" => ^message_id}]} =
               Conversations.list_group_conversation_messages(
                 group_id,
                 conversation["conversation_id"]
               )
    end

    test "send_message commits validated inline Task refs in ordered content and keeps legacy refs additive",
         %{group_id: group_id, agent_id: agent_id} do
      parent = seed_group_conversation(group_id, agent_id, %{"title" => "Parent chat"})

      task =
        seed_group_conversation(group_id, agent_id, %{
          "kind" => "agent_task",
          "title" => "Known Task"
        })

      canonical_inline_ref = %{
        "type" => "conversation_ref",
        "conversation_id" => task["conversation_id"],
        "kind" => "agent_task",
        "presentation" => "inline"
      }

      inline_ref = Map.put(canonical_inline_ref, "caller_secret", "must-not-reach-provenance")

      content = [
        %{"type" => "text", "text" => "Progress on "},
        inline_ref,
        %{"type" => "text", "text" => " is ready; compare it with "},
        inline_ref,
        %{"type" => "text", "text" => "."}
      ]

      assert {:ok, %{"message_id" => message_id}} =
               call(agent_id, "internal", "internal.send_message", "internal", %{
                 "conversation_id" => parent["conversation_id"],
                 "request_id" => "inline-task-ordered",
                 "content" => content
               })

      assert {:ok, %{"message_id" => ^message_id, "inserted" => false}} =
               call(agent_id, "internal", "internal.send_message", "internal", %{
                 "conversation_id" => parent["conversation_id"],
                 "request_id" => "inline-task-ordered",
                 "content" => content
               })

      assert {:ok, message} =
               Conversations.get_group_conversation_message(
                 group_id,
                 parent["conversation_id"],
                 message_id
               )

      assert message["content"] == content

      assert message["owner_inline_task_refs_v1"] == [
               canonical_inline_ref,
               canonical_inline_ref
             ]

      legacy_ref = %{
        "type" => "conversation_ref",
        "conversation_id" => Ids.new_conversation_id(),
        "kind" => "user_chat"
      }

      future_presentation_ref = Map.put(legacy_ref, "presentation", "card")

      assert {:ok, %{"message_id" => legacy_message_id}} =
               call(agent_id, "internal", "internal.send_message", "internal", %{
                 "conversation_id" => parent["conversation_id"],
                 "request_id" => "legacy-and-future-ref",
                 "content" => [legacy_ref, future_presentation_ref]
               })

      assert {:ok, legacy_message} =
               Conversations.get_group_conversation_message(
                 group_id,
                 parent["conversation_id"],
                 legacy_message_id
               )

      assert legacy_message["content"] == [legacy_ref, future_presentation_ref]
      refute Map.has_key?(legacy_message, "owner_inline_task_refs_v1")
    end

    test "conversation owner builds versioned inline Task provenance outside caller fields",
         %{group_id: group_id, agent_id: agent_id} do
      parent = seed_group_conversation(group_id, agent_id, %{"title" => "Parent chat"})
      non_task = seed_group_conversation(group_id, agent_id, %{"title" => "Not a Task"})

      task =
        seed_group_conversation(group_id, agent_id, %{
          "kind" => "agent_task",
          "title" => "Known Task"
        })

      forged_ref = %{
        "type" => "conversation_ref",
        "conversation_id" => non_task["conversation_id"],
        "kind" => "agent_task",
        "presentation" => "inline"
      }

      assert {:ok, %{"message_id" => spoof_message_id}} =
               ConversationServer.append_group_conversation_agent_message(
                 group_id,
                 parent["conversation_id"],
                 agent_id,
                 %{
                   "content" => "Caller metadata is not provenance",
                   "client_request_id" => "spoofed-inline-provenance",
                   "metadata" => %{
                     "validated_inline_task_refs" => [forged_ref]
                   },
                   "validated_inline_task_refs" => [forged_ref],
                   "owner_inline_task_refs_v1" => [forged_ref],
                   validated_inline_task_refs: [forged_ref],
                   owner_inline_task_refs_v1: [forged_ref]
                 }
               )

      assert {:ok, spoof_message} =
               Conversations.get_group_conversation_message(
                 group_id,
                 parent["conversation_id"],
                 spoof_message_id
               )

      assert spoof_message["metadata"]["validated_inline_task_refs"] == [forged_ref]
      refute Map.has_key?(spoof_message, "validated_inline_task_refs")
      refute Map.has_key?(spoof_message, :validated_inline_task_refs)
      refute Map.has_key?(spoof_message, "owner_inline_task_refs_v1")
      refute Map.has_key?(spoof_message, :owner_inline_task_refs_v1)

      assert {:error, {:bad_request, "inline Task conversation_ref must target an agent_task"}} =
               ConversationServer.append_group_conversation_agent_message(
                 group_id,
                 parent["conversation_id"],
                 agent_id,
                 %{
                   "content" => [forged_ref],
                   "client_request_id" => "forged-inline-target",
                   "metadata" => %{
                     "validated_inline_task_refs" => [forged_ref]
                   },
                   "validated_inline_task_refs" => [forged_ref],
                   "owner_inline_task_refs_v1" => [forged_ref],
                   validated_inline_task_refs: [forged_ref],
                   owner_inline_task_refs_v1: [forged_ref]
                 }
               )

      canonical_inline_ref = %{
        "type" => "conversation_ref",
        "conversation_id" => task["conversation_id"],
        "kind" => "agent_task",
        "presentation" => "inline"
      }

      inline_ref = Map.put(canonical_inline_ref, "caller_secret", "must-not-reach-provenance")

      attrs = %{
        "content" => [%{"type" => "text", "text" => "See "}, inline_ref],
        "client_request_id" => "owner-inline-provenance",
        "metadata" => %{
          "validated_inline_task_refs" => [forged_ref]
        },
        "validated_inline_task_refs" => [forged_ref],
        "owner_inline_task_refs_v1" => [forged_ref],
        validated_inline_task_refs: [forged_ref],
        owner_inline_task_refs_v1: [forged_ref]
      }

      assert {:ok, %{"message_id" => message_id, "inserted" => true}} =
               ConversationServer.append_group_conversation_agent_message(
                 group_id,
                 parent["conversation_id"],
                 agent_id,
                 attrs
               )

      assert {:ok, %{"message_id" => ^message_id, "inserted" => false}} =
               ConversationServer.append_group_conversation_agent_message(
                 group_id,
                 parent["conversation_id"],
                 agent_id,
                 attrs
               )

      assert {:ok, message} =
               Conversations.get_group_conversation_message(
                 group_id,
                 parent["conversation_id"],
                 message_id
               )

      assert message["owner_inline_task_refs_v1"] == [canonical_inline_ref]
      assert message["metadata"]["validated_inline_task_refs"] == [forged_ref]

      refute get_in(message, ["owner_inline_task_refs_v1", Access.at(0)])["caller_secret"]

      assert is_binary(message["request_fingerprint"])

      expected_public_content = attrs["content"]

      assert {:ok, %{"messages" => public_messages}} =
               call(agent_id, "internal", "internal.read_conversation", "internal", %{
                 "conversation_id" => parent["conversation_id"],
                 "message_id" => message_id
               })

      assert [%{"content" => ^expected_public_content} = public_message] = public_messages
      refute Map.has_key?(public_message, "owner_inline_task_refs_v1")
      refute Map.has_key?(public_message, "metadata")

      reserve_attrs = %{
        "actor_type" => "agent",
        "agent_id" => agent_id,
        "content" => [inline_ref],
        "client_request_id" => "reserved-owner-inline-provenance",
        "metadata" => %{
          "validated_inline_task_refs" => [forged_ref]
        },
        "validated_inline_task_refs" => [forged_ref],
        "owner_inline_task_refs_v1" => [forged_ref],
        validated_inline_task_refs: [forged_ref],
        owner_inline_task_refs_v1: [forged_ref]
      }

      assert {:ok, %{"message_id" => reserved_message_id}} =
               ConversationServer.reserve_group_conversation_message(
                 group_id,
                 parent["conversation_id"],
                 reserve_attrs
               )

      assert {:ok, %{"message_id" => ^reserved_message_id, "inserted" => true}} =
               ConversationServer.append_group_conversation_agent_message(
                 group_id,
                 parent["conversation_id"],
                 agent_id,
                 reserve_attrs
               )

      assert {:ok, reserved_message} =
               Conversations.get_group_conversation_message(
                 group_id,
                 parent["conversation_id"],
                 reserved_message_id
               )

      assert reserved_message["owner_inline_task_refs_v1"] == [
               canonical_inline_ref
             ]
    end

    test "send_message rejects untrusted inline Task targets",
         %{group_id: group_id, agent_id: agent_id} do
      parent = seed_group_conversation(group_id, agent_id, %{"title" => "Parent chat"})
      non_task = seed_group_conversation(group_id, agent_id, %{"title" => "Not a Task"})

      assert {:error, "inline Task conversation_ref must target an agent_task"} =
               call(agent_id, "internal", "internal.send_message", "internal", %{
                 "conversation_id" => parent["conversation_id"],
                 "content" => [
                   %{
                     "type" => "conversation_ref",
                     "conversation_id" => non_task["conversation_id"],
                     "kind" => "agent_task",
                     "presentation" => "inline"
                   }
                 ]
               })

      assert {:error, "inline Task conversation_ref is unavailable"} =
               call(agent_id, "internal", "internal.send_message", "internal", %{
                 "conversation_id" => parent["conversation_id"],
                 "content" => [
                   %{
                     "type" => "conversation_ref",
                     "conversation_id" => Ids.new_conversation_id(),
                     "kind" => "agent_task",
                     "presentation" => "inline"
                   }
                 ]
               })

      assert {:error, "inline Task conversation_ref.kind must be agent_task"} =
               call(agent_id, "internal", "internal.send_message", "internal", %{
                 "conversation_id" => parent["conversation_id"],
                 "content" => [
                   %{
                     "type" => "conversation_ref",
                     "conversation_id" => non_task["conversation_id"],
                     "kind" => "user_chat",
                     "presentation" => "inline"
                   }
                 ]
               })

      task =
        seed_group_conversation(group_id, agent_id, %{
          "kind" => "agent_task",
          "title" => "Bounded refs"
        })

      ref = %{
        "type" => "conversation_ref",
        "conversation_id" => task["conversation_id"],
        "kind" => "agent_task",
        "presentation" => "inline"
      }

      assert {:error, "content exceeds the 16 inline Task reference limit"} =
               call(agent_id, "internal", "internal.send_message", "internal", %{
                 "conversation_id" => parent["conversation_id"],
                 "content" => List.duplicate(ref, 17)
               })

      assert {:ok, []} =
               Conversations.list_group_conversation_messages(
                 group_id,
                 parent["conversation_id"]
               )
    end

    test "update_conversation changes Task status without a control Message", %{
      tenant: tenant,
      group_id: group_id,
      agent_id: delegator_id
    } do
      {:ok, worker} =
        create_control_agent(
          %{"name" => "Completion worker", "group_id" => group_id, "role" => "worker"},
          tenant
        )

      worker_id = worker["agent_id"]
      command = "Build the requested artifact"

      task_attrs = %{
        "content" => command,
        "client_request_id" => "provider-completion-task"
      }

      assert {:ok, conversation_id} =
               ConversationServer.reserve_task_conversation_id(
                 group_id,
                 delegator_id,
                 worker_id,
                 task_attrs
               )

      assert {:ok, %{"conversation_id" => ^conversation_id}} =
               SalixIM.TaskConversationInput.create_with_id(
                 group_id,
                 conversation_id,
                 delegator_id,
                 worker_id,
                 task_attrs
                 |> Map.put("schedule", %{"schedule_id" => nil, "command" => command})
                 |> Map.put("initial_message_attrs", %{
                   "kind" => "message",
                   "actor_type" => "agent",
                   "agent_id" => delegator_id,
                   "content" => command,
                   "metadata" => %{"message_type" => "task_command"},
                   "client_request_id" => "delegate-task-" <> conversation_id
                 })
               )

      assert {:ok, initial_messages} =
               Conversations.list_group_conversation_messages(group_id, conversation_id)

      assert length(initial_messages) == 1

      assert {:ok, %{"inserted" => true, "message_id" => message_id}} =
               call(
                 worker_id,
                 "internal",
                 "internal.send_message",
                 "internal",
                 %{
                   "conversation_id" => conversation_id,
                   "request_id" => "provider-worker-result",
                   "content" => [%{"type" => "text", "text" => "The artifact is ready."}]
                 }
               )

      assert {:error, "operation is not authorized for this agent role"} =
               call(
                 worker_id,
                 "internal",
                 "internal.update_conversation",
                 "internal",
                 %{
                   "conversation_id" => conversation_id,
                   "status" => "ready_for_review"
                 }
               )

      assert {:ok,
              %{
                "conversation_id" => ^conversation_id,
                "status" => "ready_for_review",
                "updated" => true,
                "updated_at" => review_version
              }} =
               call(
                 delegator_id,
                 "internal",
                 "internal.update_conversation",
                 "internal",
                 %{
                   "conversation_id" => conversation_id,
                   "status" => "ready_for_review"
                 }
               )

      assert is_integer(review_version) and review_version > 0

      assert {:ok, task} = Conversations.get_group_conversation(group_id, conversation_id)
      assert task["status"] == "ready_for_review"
      refute Map.has_key?(task, "task_completion")
      refute Map.has_key?(task, "task_last_command_seq")

      assert {:ok, messages_after_update} =
               Conversations.list_group_conversation_messages(group_id, conversation_id)

      assert Enum.map(messages_after_update, & &1["message_id"]) ==
               Enum.map(initial_messages, & &1["message_id"]) ++ [message_id]

      assert {:ok, %{"inserted" => true}} =
               call(
                 delegator_id,
                 "internal",
                 "internal.send_message",
                 "internal",
                 %{
                   "conversation_id" => conversation_id,
                   "request_id" => "provider-task-follow-up",
                   "content" => [%{"type" => "text", "text" => "Please add keyboard controls."}]
                 }
               )

      assert {:ok, unchanged_status} =
               Conversations.get_group_conversation(group_id, conversation_id)

      assert unchanged_status["status"] == "ready_for_review"

      assert {:error, "operation is not authorized for this agent role"} =
               call(worker_id, "internal", "internal.update_conversation", "internal", %{
                 "conversation_id" => conversation_id,
                 "status" => "completed"
               })

      for status <- ~w(completed completed active completed) do
        assert {:ok, %{"status" => ^status}} =
                 call(delegator_id, "internal", "internal.update_conversation", "internal", %{
                   "conversation_id" => conversation_id,
                   "status" => status
                 })
      end

      assert {:ok, %{"inserted" => true}} =
               call(delegator_id, "internal", "internal.send_message", "internal", %{
                 "conversation_id" => conversation_id,
                 "content" => [%{"type" => "text", "text" => "Correct the same delivery."}]
               })

      assert {:ok, %{"status" => "completed"}} =
               Conversations.get_group_conversation(group_id, conversation_id)
    end

    @tag :message_replies
    test "reply targets support Router and distinct Workers and reject another conversation",
         %{group_id: group_id, agent_id: router_id, tenant: tenant} do
      workers =
        for name <- ["Reply worker A", "Reply worker B"] do
          {:ok, worker} =
            create_control_agent(
              %{"name" => name, "group_id" => group_id, "role" => "worker"},
              tenant
            )

          worker["agent_id"]
        end

      participants =
        for id <- [router_id | workers] do
          %{
            "actor_type" => "agent",
            "agent_id" => id,
            "role_label" => if(id == router_id, do: "router", else: "worker"),
            "state" => "active",
            "notification_filter" => %{"messages" => "none", "statuses" => "none"}
          }
        end

      conversation =
        seed_group_conversation(group_id, router_id, %{"participants" => participants})

      cid = conversation["conversation_id"]

      send_message = fn actor, conversation_id, target, key ->
        call(actor, "internal", "internal.send_message", "internal", %{
          "conversation_id" => conversation_id,
          "reply_to_message_id" => target,
          "request_id" => key,
          "content" => [%{"type" => "text", "text" => key}],
          "delivery_filter" => %{"participant_ids" => []}
        })
      end

      assert {:ok, %{"message_id" => root_id}} = send_message.(router_id, cid, nil, "root")
      [worker_a, worker_b] = workers
      assert {:ok, %{"message_id" => a_id}} = send_message.(worker_a, cid, root_id, "worker-a")
      assert {:ok, %{"message_id" => b_id}} = send_message.(worker_b, cid, a_id, "worker-b")

      assert {:ok, %{"message_id" => router_reply_id}} =
               send_message.(router_id, cid, b_id, "router-reply")

      assert {:ok, %{"message_id" => sibling_id}} =
               send_message.(worker_b, cid, root_id, "root-sibling")

      for {id, target} <- [
            {root_id, nil},
            {a_id, root_id},
            {b_id, a_id},
            {router_reply_id, b_id},
            {sibling_id, root_id}
          ] do
        assert {:ok, message} = Conversations.get_group_conversation_message(group_id, cid, id)
        assert message["reply_to_message_id"] == target
        assert message["thread_root_message_id"] == root_id
      end

      {:ok, owner} = SalixIM.ConversationPlacement.ensure_started(group_id, cid)
      SystemsRuntime.Server.stop(owner)

      assert {:ok, %{"message_id" => ^b_id}} = send_message.(worker_b, cid, a_id, "worker-b")

      assert {:ok, tail} =
               Conversations.list_group_conversation_messages(group_id, cid, tail: 2)

      assert length(tail) == 2
      assert Enum.all?(tail, &(&1["thread_root_message_id"] == root_id))
      refute Enum.any?(tail, &(&1["message_id"] in [root_id, a_id]))

      assert {:error,
              {:bad_request, "thread_root_message_id is assigned by the conversation owner"}} =
               ConversationServer.append_group_conversation_agent_message(
                 group_id,
                 cid,
                 router_id,
                 %{
                   "content" => "A caller must not choose thread ownership.",
                   "reply_to_message_id" => a_id,
                   "thread_root_message_id" => b_id,
                   "delivery_filter" => %{"participant_ids" => []}
                 }
               )

      reserved_attrs = %{
        "actor_type" => "agent",
        "agent_id" => router_id,
        "content" => "Reserved standalone root",
        "idempotency_key" => "reserved-thread",
        "delivery_filter" => %{"participant_ids" => []}
      }

      assert {:ok, %{"message_id" => reserved_id}} =
               ConversationServer.reserve_group_conversation_message(
                 group_id,
                 cid,
                 reserved_attrs
               )

      assert {:ok, %{"message_id" => ^reserved_id}} =
               ConversationServer.append_group_conversation_message(group_id, cid, reserved_attrs)

      assert {:ok, %{"thread_root_message_id" => ^reserved_id}} =
               Conversations.get_group_conversation_message(group_id, cid, reserved_id)

      foreign = seed_group_conversation(group_id, router_id, %{})

      assert {:ok, %{"message_id" => foreign_id}} =
               send_message.(router_id, foreign["conversation_id"], nil, "foreign")

      assert {:error, "reply_to_message_id must refer to a message in this conversation"} =
               send_message.(worker_a, cid, foreign_id, "wrong-conversation")
    end

    test "Worker milestones are recorded for people without waking the Router",
         %{group_id: group_id, agent_id: router_id, tenant: tenant} do
      {:ok, worker} =
        create_control_agent(
          %{"name" => "Milestone worker", "group_id" => group_id, "role" => "worker"},
          tenant
        )

      participants =
        for {id, role} <- [{router_id, "router"}, {worker["agent_id"], "worker"}] do
          %{
            "actor_type" => "agent",
            "agent_id" => id,
            "role_label" => role,
            "state" => "active",
            "notification_filter" => %{"messages" => "all", "statuses" => "none"}
          }
        end

      cid =
        seed_group_conversation(group_id, router_id, %{"participants" => participants})[
          "conversation_id"
        ]

      send = fn content ->
        call(worker["agent_id"], "internal", "internal.send_message", "internal", %{
          "conversation_id" => cid,
          "content" => content
        })
      end

      stored = fn message_id ->
        {:ok, message} = Conversations.get_group_conversation_message(group_id, cid, message_id)
        message
      end

      milestone = &%{"type" => "milestone", "title" => &1}

      # Steps finished together are recorded together, for people only.
      assert {:ok, %{"message_id" => alone_id}} =
               send.([milestone.("  Wrote the invite\n for Alice "), milestone.("Wrote Bob's")])

      alone = stored.(alone_id)

      assert alone["content"] == [
               milestone.("Wrote the invite for Alice"),
               milestone.("Wrote Bob's")
             ]

      assert alone["delivery_filter"] == %{"participant_ids" => []}

      # Beside a result the Message reaches the Router as usual.
      assert {:ok, %{"message_id" => result_id}} =
               send.([
                 %{"type" => "text", "text" => "Sent to A, B and C."},
                 milestone.("Sent the emails")
               ])

      result = stored.(result_id)

      assert result["content"] == [
               milestone.("Sent the emails"),
               %{"type" => "text", "text" => "Sent to A, B and C."}
             ]

      assert result["delivery_filter"] == nil

      assert {:error, "Each milestone title must be one line of 1 to 80 characters"} =
               send.([milestone.(String.duplicate("x", 81))])

      assert {:error, "A Message carries at most 20 milestones"} =
               send.(Enum.map(1..21, &milestone.("Step #{&1}")))

      assert {:error, {:bad_request, "Only an Agent can record a milestone"}} =
               SalixIM.ConversationMessage.prepare(%{
                 "kind" => "message",
                 "actor_type" => "user",
                 "user_id" => "current",
                 "content" => [milestone.("Not mine")]
               })
    end

    test "every Agent append records milestone-only Messages for people, not only the send tool",
         %{group_id: group_id, agent_id: router_id} do
      cid = seed_group_conversation(group_id, router_id, %{})["conversation_id"]

      assert {:ok, %{"message_id" => message_id}} =
               SalixIM.ConversationServer.append_group_conversation_agent_message(
                 group_id,
                 cid,
                 router_id,
                 %{
                   "kind" => "message",
                   "actor_type" => "agent",
                   "agent_id" => router_id,
                   "content" => [
                     %{"type" => "milestone", "title" => " Read the\nrequest "}
                   ]
                 }
               )

      {:ok, message} = Conversations.get_group_conversation_message(group_id, cid, message_id)
      assert message["content"] == [%{"type" => "milestone", "title" => "Read the request"}]
      assert message["delivery_filter"] == %{"participant_ids" => []}
    end

    test "a Router's Message that hands a Task a request made elsewhere is marked for its Activity",
         %{group_id: group_id, agent_id: router_id} do
      participants = [
        %{
          "actor_type" => "agent",
          "agent_id" => router_id,
          "role_label" => "delegator",
          "state" => "active",
          "notification_filter" => %{"messages" => "all", "statuses" => "none"}
        }
      ]

      task_id =
        seed_group_conversation(group_id, router_id, %{
          "kind" => "agent_task",
          "participants" => participants
        })["conversation_id"]

      home_id = seed_group_conversation(group_id, router_id, %{})["conversation_id"]

      {:ok, %{"message_id" => request_id}} =
        SalixIM.ConversationServer.append_group_conversation_message(group_id, home_id, %{
          "actor_type" => "user",
          "user_id" => "current",
          "content" => "Rewrite the invites for a smaller room.",
          "delivery_filter" => %{"participant_ids" => []}
        })

      {:ok, request} = Conversations.get_group_conversation_message(group_id, home_id, request_id)

      {:ok, home_source} =
        SalixIM.ConversationSourceIdentity.encode(home_id, request_id, request["participant_id"])

      send = fn text, tool_context ->
        {:ok, %{"message_id" => message_id}} =
          call(
            router_id,
            "internal",
            "internal.send_message",
            "internal",
            %{"conversation_id" => task_id, "content" => [%{"type" => "text", "text" => text}]},
            %{"tool_context" => tool_context}
          )

        {:ok, message} =
          Conversations.get_group_conversation_message(group_id, task_id, message_id)

        message
      end

      # Woken by a person's Message in Home: it hands the Task a request.
      handed_in = send.("Rewrite the invites.", %{"source_message_id" => home_source})
      assert handed_in["metadata"]["task_request"] == true

      # Woken by a Message of the Task itself: it answers that Message.
      {:ok, task_source} =
        SalixIM.ConversationSourceIdentity.encode(
          task_id,
          handed_in["message_id"],
          handed_in["participant_id"]
        )

      answer = send.("On it.", %{"source_message_id" => task_source})
      assert answer["reply_to_message_id"] == handed_in["message_id"]
      refute Map.has_key?(answer["metadata"], "task_request")

      # Without a waking delivery, such as on a timer, it hands in nothing.
      own = send.("Checking the room size.", %{})
      refute Map.has_key?(own["metadata"], "task_request")
    end

    @tag :message_replies
    test "thread backfill preserves historical facts and resumes after a segment write failure",
         %{group_id: group_id, agent_id: agent_id} do
      conversation = seed_group_conversation(group_id, agent_id, %{})
      cid = conversation["conversation_id"]

      send_message = fn target, key ->
        ConversationServer.append_group_conversation_agent_message(group_id, cid, agent_id, %{
          "content" => key,
          "reply_to_message_id" => target,
          "idempotency_key" => key,
          "delivery_filter" => %{"participant_ids" => []}
        })
      end

      assert {:ok, %{"message_id" => root_id}} = send_message.(nil, "old-root")
      assert {:ok, %{"message_id" => parent_id}} = send_message.(root_id, "old-parent")
      for n <- 1..36, do: assert({:ok, _} = send_message.(parent_id, "old-child-#{n}"))
      {:ok, before} = Conversations.list_group_conversation_messages(group_id, cid, limit: 100)
      {:ok, meta} = Conversations.get_group_conversation(group_id, cid)
      segment = meta["current_message_segment"]
      segment_key = Keys.ctl_group_conversation_message_segment(group_id, cid, segment)
      index_key = Keys.ctl_group_conversation_message_segment_index(group_id, cid, segment)
      {:ok, %{body: body, etag: etag}} = SalixStore.S3.get(segment_key)
      {:ok, rows} = SalixIM.ConversationMessageCodec.decode_segment(body)
      legacy = Enum.map(rows, &Map.delete(&1, "thread_root_message_id"))
      legacy_body = Enum.map_join(legacy, &(Jason.encode!(&1) <> "\n"))
      {:ok, %{body: index_body}} = SalixStore.S3.get(index_key)

      legacy_index =
        Map.merge(
          Jason.decode!(index_body),
          SalixIM.ConversationMessageCodec.segment_facts(legacy, legacy_body)
        )

      # Install historical storage before a new owner loads it. A live owner
      # retains current rows, so rewriting storage beneath it is not an upgrade.
      SalixIM.TestSupport.Fleet.stop_all!()
      assert {:ok, _} = SalixStore.S3.put(segment_key, legacy_body, if_match: etag)
      assert {:ok, _} = SalixStore.S3.put(index_key, Jason.encode!(legacy_index))

      assert {:error, {:conflict, _}} = send_message.(parent_id, "await-backfill")
      SalixStore.S3.Fake.set_fault({:ambiguous_after, :put, segment_key})

      assert {:error, {:ambiguous, :injected}} =
               ConversationServer.backfill_message_threads(group_id, cid)

      assert {:ok, %{after_seq: 32, done: false}} =
               ConversationServer.backfill_message_threads(group_id, cid)

      assert {:ok, %{after_seq: 38, updated: 6, done: true}} =
               ConversationServer.backfill_message_threads(group_id, cid, 32)

      assert {:ok, %{updated: 0}} = ConversationServer.backfill_message_threads(group_id, cid)

      {:ok, after_messages} =
        Conversations.list_group_conversation_messages(group_id, cid, limit: 100)

      assert after_messages == before
      assert Enum.all?(after_messages, &(&1["thread_root_message_id"] == root_id))

      assert {:ok, %{body: ^legacy_body}} =
               SalixStore.S3.get(
                 Keys.ctl_group_conversation_message_thread_backup(group_id, cid, segment)
               )

      assert {:ok, restored} = SalixIM.ConversationMessageCodec.decode_segment(legacy_body)
      assert restored == legacy

      assert {:ok, %{"message_id" => ^parent_id, "inserted" => false}} =
               send_message.(root_id, "old-parent")

      assert {:ok, %{"message_id" => child_id}} = send_message.(parent_id, "await-backfill")

      assert {:ok, %{"thread_root_message_id" => ^root_id}} =
               Conversations.get_group_conversation_message(group_id, cid, child_id)
    end

    @tag :message_replies
    test "ordinary sends use the accepted source, honor explicit targets, and preserve committed retries",
         %{group_id: group_id, agent_id: agent_id} do
      conv = seed_group_conversation(group_id, agent_id, %{})
      cid = conv["conversation_id"]

      {:ok, %{"participants" => participants}} =
        Conversations.list_group_conversation_participants(group_id, cid)

      user = Enum.find(participants, &(&1["actor_type"] == "user"))
      agent = Enum.find(participants, &(&1["agent_id"] == agent_id))

      append_user = fn text ->
        assert {:ok, %{"message_id" => id}} =
                 ConversationServer.append_group_conversation_message(group_id, cid, %{
                   "actor_type" => "user",
                   "participant_id" => user["participant_id"],
                   "content" => text,
                   "delivery_filter" => %{"participant_ids" => []}
                 })

        id
      end

      pr_id = append_user.("Show my recent PRs.")
      slack_id = append_user.("Show my Slack messages.")
      source = fn id -> "groupconv:#{cid}:#{id}:#{agent["participant_id"]}" end
      pr_source = source.(pr_id)
      slack_source = source.(slack_id)
      context = %{"source_message_ids" => [pr_source], "source_message_id" => pr_source}

      send_message = fn key, extra, tool_context ->
        call(
          agent_id,
          "internal",
          "internal.send_message",
          "internal",
          Map.merge(
            %{
              "conversation_id" => cid,
              "request_id" => key,
              "content" => [%{"type" => "text", "text" => key}],
              "delivery_filter" => %{"participant_ids" => []}
            },
            extra
          ),
          %{"tool_context" => tool_context}
        )
      end

      read = fn id ->
        assert {:ok, message} = Conversations.get_group_conversation_message(group_id, cid, id)
        message
      end

      assert {:ok, %{"message_id" => reply_id}} = send_message.("pr-reply", %{}, context)
      assert read.(reply_id)["reply_to_message_id"] == pr_id
      assert {:ok, %{"message_id" => ^reply_id}} = send_message.("pr-reply", %{}, context)

      assert {:ok, %{"message_id" => explicit_id}} =
               send_message.("explicit", %{"reply_to_message_id" => slack_id}, context)

      assert read.(explicit_id)["reply_to_message_id"] == slack_id

      assert {:error, conflict} =
               send_message.("explicit", %{"reply_to_message_id" => pr_id}, context)

      assert conflict =~ "different content"

      assert {:ok, %{"message_id" => independent_id}} =
               send_message.("independent", %{"reply_to_message_id" => nil}, context)

      refute Map.has_key?(read.(independent_id), "reply_to_message_id")

      assert {:ok, %{"message_id" => batch_id}} =
               send_message.("batch", %{}, %{"source_message_ids" => [pr_source, slack_source]})

      assert read.(batch_id)["reply_to_message_id"] == slack_id

      assert {:ok, %{"message_id" => current_id}} =
               send_message.("current", %{}, %{
                 "source_message_ids" => [pr_source, slack_source],
                 "source_message_id" => pr_source
               })

      assert read.(current_id)["reply_to_message_id"] == pr_id

      assert {:ok, %{"message_id" => agent_reply_id}} =
               send_message.("agent-reply", %{}, %{"source_message_id" => source.(reply_id)})

      assert read.(agent_reply_id)["reply_to_message_id"] == reply_id

      foreign = seed_group_conversation(group_id, agent_id, %{})
      foreign_cid = foreign["conversation_id"]

      {:ok, %{"participants" => foreign_participants}} =
        Conversations.list_group_conversation_participants(group_id, foreign_cid)

      foreign_user = Enum.find(foreign_participants, &(&1["actor_type"] == "user"))
      foreign_agent = Enum.find(foreign_participants, &(&1["agent_id"] == agent_id))

      assert {:ok, %{"message_id" => foreign_message_id}} =
               ConversationServer.append_group_conversation_message(group_id, foreign_cid, %{
                 "actor_type" => "user",
                 "participant_id" => foreign_user["participant_id"],
                 "content" => "A request in another conversation.",
                 "delivery_filter" => %{"participant_ids" => []}
               })

      foreign_source =
        "groupconv:#{foreign_cid}:#{foreign_message_id}:#{foreign_agent["participant_id"]}"

      for {label, latest_source} <- [
            {"foreign", foreign_source},
            {"external", "slack:other:source"}
          ] do
        assert {:ok, %{"message_id" => id}} =
                 send_message.(label, %{}, %{
                   "source_message_ids" => [pr_source, latest_source],
                   "source_message_id" => latest_source
                 })

        refute Map.has_key?(read.(id), "reply_to_message_id")
      end

      # A committed reply from before automatic association remains an exact retry.
      assert {:ok, %{"message_id" => legacy_id}} = send_message.("legacy-retry", %{}, %{})
      assert {:ok, %{"message_id" => ^legacy_id}} = send_message.("legacy-retry", %{}, context)
      refute Map.has_key?(read.(legacy_id), "reply_to_message_id")
    end

    test "update_conversation validates authorization and generic fields at the tool boundary",
         %{tenant: tenant, group_id: group_id, agent_id: agent_id} do
      conv = seed_group_conversation(group_id, agent_id, %{"title" => "Artifact run"})
      cid = conv["conversation_id"]

      base = %{"conversation_id" => cid}

      assert {:ok, outsider} =
               create_control_agent(
                 %{"name" => "Conversation outsider", "group_id" => group_id, "role" => "router"},
                 tenant
               )

      assert {:error, "current Agent is not a Conversation participant"} =
               call(
                 outsider["agent_id"],
                 "internal",
                 "internal.update_conversation",
                 "internal",
                 Map.put(base, "status", "ready_for_review")
               )

      assert {:error, "status must be a string when present"} =
               call(
                 agent_id,
                 "internal",
                 "internal.update_conversation",
                 "internal",
                 Map.put(base, "status", 5)
               )

      assert {:error, "latest_artifact must be a JSON object when present"} =
               call(
                 agent_id,
                 "internal",
                 "internal.update_conversation",
                 "internal",
                 Map.put(base, "latest_artifact", "/x.md")
               )

      assert {:error, "conversation update requires at least one mutable field"} =
               call(
                 agent_id,
                 "internal",
                 "internal.update_conversation",
                 "internal",
                 base
               )
    end

    test "send_message records a user_chat group conversation result with idempotent inserted",
         %{group_id: group_id, agent_id: agent_id} do
      conv = seed_group_conversation(group_id, agent_id, %{"title" => "Ops"})
      cid = conv["conversation_id"]

      assert {:ok, %{"inserted" => true, "message_id" => user_message_id}} =
               ConversationServer.append_group_conversation_message(group_id, cid, %{
                 "client_request_id" => "r-1",
                 "content" => [%{"type" => "text", "text" => "user request"}]
               })

      assert Ids.valid_message_id?(user_message_id)

      params = %{
        "conversation_id" => cid,
        "request_id" => "r-1",
        "content" => [%{"type" => "text", "text" => "status update"}]
      }

      assert {:ok, result} =
               call(agent_id, "internal", "internal.send_message", "internal", params)

      message_id = result["message_id"]

      assert result == %{
               "sent" => true,
               "conversation_id" => cid,
               "message_id" => message_id,
               "inserted" => true,
               "delivery_status" => "recorded"
             }

      assert Ids.valid_message_id?(message_id)
      refute message_id == user_message_id

      # Same request id again: recorded once, inserted false.
      assert {:ok, retry} =
               call(agent_id, "internal", "internal.send_message", "internal", params)

      assert retry["inserted"] == false
      assert retry["message_id"] == message_id

      {:ok, messages} = Conversations.list_group_conversation_messages(group_id, cid)
      sent = Enum.filter(messages, &(&1["message_id"] == message_id))
      assert [%{"actor_type" => "agent", "participant_id" => participant_id}] = sent
      assert Ids.valid_participant_id?(participant_id)
    end

    test "send_message defaults idempotency to namespaced tool call id",
         %{group_id: group_id, agent_id: agent_id} do
      conv = seed_group_conversation(group_id, agent_id, %{"title" => "Ops"})
      cid = conv["conversation_id"]

      params = %{
        "conversation_id" => cid,
        "content" => [%{"type" => "text", "text" => "tool-call reply"}]
      }

      assert {:ok, result} =
               call(agent_id, "internal", "internal.send_message", "internal", params, %{
                 "tool_call_id" => "tool-call-1"
               })

      assert result["inserted"] == true
      assert Ids.valid_message_id?(result["message_id"])
      refute result["message_id"] == "tool-call-1"

      assert {:ok, retry} =
               call(agent_id, "internal", "internal.send_message", "internal", params, %{
                 "tool_call_id" => "tool-call-1"
               })

      assert retry["inserted"] == false
      assert retry["message_id"] == result["message_id"]

      {:ok, messages} = Conversations.list_group_conversation_messages(group_id, cid)

      assert 1 ==
               Enum.count(messages, fn message ->
                 message["message_id"] == result["message_id"] and
                   message["actor_type"] == "agent"
               end)
    end

    test "send_message fans out to active wakeable agent participants except the sender agent",
         %{tenant: tenant, group_id: group_id} do
      previous_delivery = SystemsRuntime.get_env(:salix_im, :agent_delivery_mod)
      SystemsRuntime.put_env(:salix_im, :agent_delivery_mod, FakeAgentDelivery)
      on_exit(fn -> restore(:salix_im, :agent_delivery_mod, previous_delivery) end)
      SystemsRuntime.put_env(:salix_im, :fake_agent_delivery_test_pid, SystemsRuntime.Proc.self())
      on_exit(fn -> SystemsRuntime.delete_env(:salix_im, :fake_agent_delivery_test_pid) end)

      {:ok, sender} =
        create_control_agent(
          %{"name" => "Sender", "group_id" => group_id, "role" => "worker"},
          tenant
        )

      sender_id = sender["agent_id"]

      {:ok, target} =
        create_control_agent(
          %{"name" => "Target", "group_id" => group_id, "role" => "worker"},
          tenant
        )

      {:ok, sleeping} =
        create_control_agent(
          %{"name" => "Sleeping", "group_id" => group_id, "role" => "worker"},
          tenant
        )

      conversation_id = Ids.new_conversation_id()

      conv =
        seed_group_conversation(group_id, sender_id, %{
          "conversation_id" => conversation_id,
          "participants" => [
            agent_participant(conversation_id, sender_id, "sender-a", "ses1_1100000000000000021"),
            agent_participant(
              conversation_id,
              target["agent_id"],
              "target",
              "ses1_1100000000000000023"
            ),
            agent_participant(
              conversation_id,
              sleeping["agent_id"],
              "sleeping",
              "ses1_1100000000000000024",
              %{
                "notification_filter" => %{"messages" => "none", "statuses" => "none"}
              }
            )
          ]
        })

      {:ok, %{"participants" => participants}} =
        Conversations.list_group_conversation_participants(group_id, conversation_id)

      sender_participant =
        Enum.find(participants, fn participant ->
          participant["agent_id"] == sender_id and
            get_in(participant, ["payload", "session_id"]) == "ses1_1100000000000000021"
        end)

      source_participant = Enum.find(participants, &(&1["agent_id"] == target["agent_id"]))

      assert {:ok, %{"message_id" => source_message_id}} =
               ConversationServer.append_group_conversation_message(
                 group_id,
                 conversation_id,
                 %{
                   "actor_type" => "agent",
                   "agent_id" => target["agent_id"],
                   "participant_id" => source_participant["participant_id"],
                   "client_request_id" => "fanout-source",
                   "content" => [%{"type" => "text", "text" => "please report"}]
                 }
               )

      assert {:ok, result} =
               call(
                 sender_id,
                 "internal",
                 "internal.send_message",
                 "internal",
                 %{
                   "conversation_id" => conv["conversation_id"],
                   "request_id" => "fanout-1",
                   "content" => [%{"type" => "text", "text" => "ping"}]
                 },
                 %{
                   "tool_context" => %{
                     "source_message_id" =>
                       "groupconv:#{conversation_id}:#{source_message_id}:#{sender_participant["participant_id"]}"
                   }
                 }
               )

      assert result["inserted"] == true
      assert result["delivery_status"] == "queued"

      reply =
        conv["conversation_id"]
        |> then(&Conversations.list_group_conversation_messages(group_id, &1))
        |> elem(1)
        |> Enum.find(&(&1["content"] == [%{"type" => "text", "text" => "ping"}]))

      assert reply["participant_id"] == sender_participant["participant_id"]

      target_id = target["agent_id"]
      settle_receive({:agent_delivery, ^target_id, %{content: "ping"} = payload, _})
      assert payload.session_id == "ses1_1100000000000000023"
      assert payload.content == "ping"
    end

    test "read_conversation treats agent actor_type as the current agent participant",
         %{tenant: tenant, group_id: group_id} do
      conversation_id = Ids.new_conversation_id()

      {:ok, worker} =
        create_control_agent(
          %{"name" => "Worker", "group_id" => group_id, "role" => "worker"},
          tenant
        )

      agent_id = worker["agent_id"]

      {:ok, delegator} =
        create_control_agent(
          %{"name" => "Delegator", "group_id" => group_id, "role" => "worker"},
          tenant
        )

      conv =
        seed_group_conversation(group_id, agent_id, %{
          "conversation_id" => conversation_id,
          "title" => "Task read",
          "kind" => "agent_task",
          "participants" => [
            agent_participant(conversation_id, agent_id, "worker", "ses1_1100000000000000001", %{
              "actor_type" => "agent",
              "role_label" => "worker"
            }),
            agent_participant(
              conversation_id,
              delegator["agent_id"],
              "delegator",
              "ses1_1100000000000000002",
              %{
                "actor_type" => "agent",
                "role_label" => "delegator"
              }
            )
          ],
          "messages" => [
            %{
              "message_id" => "m-1",
              "kind" => "message",
              "participant_id" => "delegator",
              "actor_type" => "agent",
              "agent_id" => delegator["agent_id"],
              "content" => [%{"type" => "text", "text" => "please compute"}],
              "created_at" => 1
            },
            %{
              "message_id" => "m-2",
              "kind" => "message",
              "participant_id" => "worker",
              "actor_type" => "agent",
              "agent_id" => agent_id,
              "content" => [%{"type" => "text", "text" => "working on it"}],
              "created_at" => 2
            }
          ]
        })

      cid = conv["conversation_id"]

      current_participant_id =
        participant_id_for_session!(group_id, cid, "ses1_1100000000000000001")

      assert {:ok, result} =
               call(
                 agent_id,
                 "internal",
                 "internal.read_conversation",
                 "internal",
                 %{"conversation_id" => cid},
                 %{"tool_context" => %{"session_id" => "ses1_1100000000000000001"}}
               )

      assert result["current_participant_id"] == current_participant_id
      assert result["state"]["own_message_count"] == 1
      assert result["state"]["peer_message_count"] == 1
      assert result["state"]["active_peer_count"] == 1

      assert {:ok, after_first} =
               call(
                 agent_id,
                 "internal",
                 "internal.read_conversation",
                 "internal",
                 %{"conversation_id" => cid, "after_seq" => 1},
                 %{"tool_context" => %{"session_id" => "ses1_1100000000000000001"}}
               )

      assert Enum.map(after_first["messages"], & &1["content"]) == [
               [%{"type" => "text", "text" => "working on it"}]
             ]

      assert after_first["state"]["own_message_count"] == 1
      assert after_first["state"]["peer_message_count"] == 0
    end

    test "list_conversation_participants returns only public participant projection",
         %{group_id: group_id, agent_id: agent_id} do
      conversation_id = Ids.new_conversation_id()

      conv =
        seed_group_conversation(group_id, agent_id, %{
          "conversation_id" => conversation_id,
          "participants" => [
            %{
              "participant_id" => "user",
              "conversation_id" => conversation_id,
              "actor_type" => "user",
              "user_id" => "current",
              "user_name" => "Customer",
              "state" => "active",
              "notification_filter" => %{"messages" => "all", "statuses" => "none"},
              "payload" => %{"secret" => "hidden"}
            },
            agent_participant(conversation_id, agent_id, "worker", "ses1_1100000000000000001", %{
              "agent_name" => "Codex",
              "state" => "inactive",
              "activity_status" => "stale-conversation-field",
              "payload" => %{
                "session_id" => "ses1_1100000000000000001",
                "codex_thread_id" => "hidden"
              }
            })
          ]
        })

      assert {:ok, result} =
               call(
                 agent_id,
                 "internal",
                 "internal.list_conversation_participants",
                 "internal",
                 %{
                   "conversation_id" => conv["conversation_id"]
                 }
               )

      assert result["conversation_id"] == conv["conversation_id"]

      assert result["participants"] |> Enum.map(& &1["type"]) |> MapSet.new() ==
               MapSet.new(["user", "agent"])

      assert Enum.find(result["participants"], &(&1["type"] == "agent"))["name"] == "Codex"
      assert is_binary(Enum.find(result["participants"], &(&1["type"] == "user"))["name"])

      assert Enum.all?(result["participants"], &Ids.valid_participant_id?(&1["participant_id"]))

      Enum.each(result["participants"], &refute_private_participant_fields/1)
    end

    test "get_conversation_participant_status keeps the other Conversation of shared work private",
         %{tenant: tenant, group_id: group_id, agent_id: agent_id} do
      session_id = "ses1_1100000000000000008"
      status_agent = create_test_agent!(tenant, group_id, "agent-status-shared", "Codex")
      task_id = Ids.new_conversation_id()

      {:ok, task_source} =
        SalixIM.ConversationSourceIdentity.encode(
          task_id,
          Ids.new_message_id(),
          Ids.new_participant_id()
        )

      # The pending input is a Worker's report from another Conversation.
      assert {:ok, _session} =
               SalixAgent.InternalSessionStore.prepare_commit(
                 status_agent["agent_id"],
                 session_id,
                 [
                   %{"type" => "status", "session_id" => session_id, "status" => "active"},
                   %{
                     "type" => "delivery",
                     "from_queue" => true,
                     "session_id" => session_id,
                     "message_id" => 1,
                     "role" => "user",
                     "source_message_id" => task_source,
                     "content" => "Worker report"
                   }
                 ],
                 create_attrs: %{"created_at" => 1_780_000_001}
               )

      conversation_id = Ids.new_conversation_id()

      participant = %{
        "actor_type" => "agent",
        "agent_id" => status_agent["agent_id"],
        "agent_name" => "Codex",
        "state" => "active",
        "payload" => %{"session_id" => session_id}
      }

      conv =
        seed_group_conversation(group_id, agent_id, %{
          "conversation_id" => conversation_id,
          "participants" => [
            agent_participant(
              conversation_id,
              status_agent["agent_id"],
              "worker",
              session_id,
              participant
            )
          ]
        })

      participant_id = participant_id_for_session!(group_id, conversation_id, session_id)

      assert {:ok, owner_view} =
               SalixIM.ConversationParticipantActivity.read(
                 group_id,
                 conversation_id,
                 participant_id,
                 participant
               )

      assert owner_view["activity"]["working_conversation_ids"] == [task_id]

      assert {:ok, result} =
               call(
                 agent_id,
                 "internal",
                 "internal.get_conversation_participant_status",
                 "internal",
                 %{
                   "conversation_id" => conv["conversation_id"],
                   "participant_id" => participant_id
                 }
               )

      assert result["activity"]["state"] == "active"
      refute Map.has_key?(result["activity"], "working_conversation_ids")
      refute Map.has_key?(result["activity"], "waiting")
      refute_status_private_fields(result)
    end

    test "participant status is scoped to the current group",
         %{tenant: tenant, agent_id: agent_id} do
      other_group_id = SalixStore.Ids.new_group_id(tenant)
      SalixAgent.TestSupport.create_control_group!(other_group_id, %{"name" => "Other"})

      other_agent = create_test_agent!(tenant, other_group_id, "#{agent_id}-other", "Other Agent")

      other =
        seed_group_conversation(other_group_id, other_agent["agent_id"], %{
          "title" => "Other group"
        })

      other_participant_id =
        participant_id_for_actor!(other_group_id, other["conversation_id"], "agent")

      assert {:error, "conversation not found"} =
               call(
                 agent_id,
                 "internal",
                 "internal.list_conversation_participants",
                 "internal",
                 %{
                   "conversation_id" => other["conversation_id"]
                 }
               )

      assert {:error, "conversation not found"} =
               call(
                 agent_id,
                 "internal",
                 "internal.get_conversation_participant_status",
                 "internal",
                 %{
                   "conversation_id" => other["conversation_id"],
                   "participant_id" => other_participant_id
                 }
               )
    end

    test "label.assign immediately adds matching existing labels without replacing human labels",
         %{agent_id: agent_id, group_id: group_id} do
      {:ok, %{"labels" => [work, personal, research | _]}} = SalixIM.TaskLabels.list(group_id)

      task =
        seed_group_conversation(group_id, agent_id, %{
          "title" => "Compare work vendors",
          "kind" => "agent_task"
        })

      cid = task["conversation_id"]

      {:ok, _} =
        ConversationServer.update_group_conversation(group_id, cid, %{
          "labels" => [personal["id"]]
        })

      assert {:ok, %{"applied" => true, "labels" => assigned}} =
               call(agent_id, "internal", "internal.label.assign", "internal", %{
                 "conversation_id" => cid,
                 "label_ids" => [work["id"], research["id"], work["id"]]
               })

      assert assigned == [personal["id"], work["id"], research["id"]]
      assert {:ok, %{"proposals" => []}} = SalixIM.TaskLabels.list(group_id)

      assert {:error, _} =
               call(agent_id, "internal", "internal.label.assign", "internal", %{
                 "conversation_id" => cid,
                 "label_ids" => [Ids.new_task_label_id()]
               })

      assert {:ok, %{"labels" => ^assigned}} = Conversations.get_group_conversation(group_id, cid)
    end

    test "label apis are router-only", %{tenant: tenant, group_id: group_id} do
      {:ok, worker} =
        create_control_agent(
          %{"name" => "Label worker", "group_id" => group_id, "role" => "worker"},
          tenant
        )

      for operation <- ["internal.label.list", "internal.label.assign", "internal.label.propose"] do
        assert {:error, "operation is not authorized for this agent role"} =
                 call(worker["agent_id"], "internal", operation, "internal", %{})
      end
    end
  end

  # ---- wechat delivery + unknown providers ----

  describe "call_api/4 wechat" do
    test "sends adapted Markdown through the selected WeChat connect and stored context",
         %{tenant: tenant, group_id: group_id, agent_id: agent_id} do
      start_supervised!(MockProviderRuntime)
      base_url = BanditServer.serve!(MockProviderRuntime)

      seed_connect(group_id, "wx1", "wechat", %{
        "tenant_id" => tenant,
        "status" => "connected",
        "wechat_id" => "wx-1",
        "base_url" => "#{base_url}",
        "token" => "wx-token",
        "latest_context_token" => "ctx-1"
      })

      assert {:ok, %{"message_id" => message_id}} =
               call(agent_id, "wechat", "wechat.reply_text", "wx1", %{
                 "text" => "## Report\n\n**Ready** *中文* ![preview](https://example.com/image.png)"
               })

      assert is_binary(message_id) and message_id != ""

      [req] = MockProviderRuntime.requests(:wechat_send)
      assert req.auth == "Bearer wx-token"
      assert req.params["msg"]["to_user_id"] == "wx-1"
      assert req.params["msg"]["context_token"] == "ctx-1"

      assert req.params["msg"]["item_list"] == [
               %{
                 "type" => 1,
                 "text_item" => %{
                   "text" => "## Report\n\n**Ready** 中文"
                 }
               }
             ]

      assert platform_messages!(group_id) == [
               %{
                 "provider" => "wechat",
                 "role" => "assistant",
                 "content" => [%{"type" => "text", "text" => "## Report\n\n**Ready** 中文"}]
               }
             ]

      assert {:ok, _} =
               call(agent_id, "wechat", "wechat.reply_text", "wx1", %{
                 "text" => "    ![literal](image.png)\n    *literal*"
               })

      code_request = List.last(MockProviderRuntime.requests(:wechat_send))
      [%{"text_item" => %{"text" => rendered}}] = code_request.params["msg"]["item_list"]

      assert [%MDEx.CodeBlock{literal: "![literal](image.png)\n*literal*\n"}] =
               MDEx.parse_document!(rendered).nodes
    end

    test "reply media only reads agent VFS paths and sends through ClawBot media upload",
         %{tenant: tenant, group_id: group_id, agent_id: agent_id} do
      start_supervised!(MockProviderRuntime)
      base_url = BanditServer.serve!(MockProviderRuntime)

      seed_connect(group_id, "wx-media", "wechat", %{
        "tenant_id" => tenant,
        "status" => "connected",
        "wechat_id" => "wx-media-user",
        "base_url" => "#{base_url}",
        "token" => "wx-token",
        "latest_context_token" => "ctx-media"
      })

      seed_agent_vfs(agent_id, %{})
      host_path = host_file!("HOST-SECRET-WECHAT")

      assert {:error, message} =
               call(agent_id, "wechat", "wechat.reply_file", "wx-media", %{
                 "path" => host_path
               })

      assert message =~ "file not found in agent VFS"
      assert MockProviderRuntime.requests(:wechat_upload_url) == []
      assert MockProviderRuntime.requests(:wechat_cdn_upload) == []
      assert MockProviderRuntime.requests(:wechat_send) == []

      seed_agent_vfs(agent_id, %{
        "/attachments/pic.png" => @png,
        "/attachments/notes.pdf" => "PDF-VFS-BYTES"
      })

      assert {:error, "path must point to an image file for wechat.reply_image"} =
               call(agent_id, "wechat", "wechat.reply_image", "wx-media", %{
                 "path" => "/attachments/notes.pdf"
               })

      assert {:ok, %{"filename" => "pic.png", "message_id" => image_message_id}} =
               call(agent_id, "wechat", "wechat.reply_image", "wx-media", %{
                 "path" => "/attachments/pic.png",
                 "caption" => "    ![literal](image.png)"
               })

      assert is_binary(image_message_id)

      assert {:ok, %{"filename" => "notes.pdf", "message_id" => file_message_id}} =
               call(agent_id, "wechat", "wechat.reply_file", "wx-media", %{
                 "path" => "/attachments/notes.pdf",
                 "caption" => "##### 附件\n\n*说明* **PDF**![图](https://example.com/image.png)"
               })

      assert is_binary(file_message_id)

      upload_reqs = MockProviderRuntime.requests(:wechat_upload_url)
      assert length(upload_reqs) == 2
      assert Enum.any?(upload_reqs, &(&1.params["rawsize"] == byte_size(@png)))
      assert Enum.any?(upload_reqs, &(&1.params["rawsize"] == byte_size("PDF-VFS-BYTES")))

      assert length(MockProviderRuntime.requests(:wechat_cdn_upload)) == 2

      sends = MockProviderRuntime.requests(:wechat_send)

      assert Enum.any?(sends, fn req ->
               case req.params["msg"]["item_list"] do
                 [%{"type" => 2, "image_item" => image}] ->
                   image["media"]["encrypt_query_param"] == "encrypted-download-param"

                 _ ->
                   false
               end
             end)

      assert Enum.any?(sends, fn req ->
               req.params["msg"]["item_list"] == [
                 %{"type" => 1, "text_item" => %{"text" => "附件\n\n说明 **PDF**"}}
               ]
             end)

      assert Enum.any?(sends, fn req ->
               case req.params["msg"]["item_list"] do
                 [%{"type" => 1, "text_item" => %{"text" => text}}] ->
                   match?(
                     [%MDEx.CodeBlock{literal: "![literal](image.png)\n"}],
                     MDEx.parse_document!(text).nodes
                   )

                 _ ->
                   false
               end
             end)

      assert Enum.any?(sends, fn req ->
               case req.params["msg"]["item_list"] do
                 [%{"type" => 4, "file_item" => file}] ->
                   file["file_name"] == "notes.pdf" and
                     file["media"]["encrypt_query_param"] == "encrypted-download-param"

                 _ ->
                   false
               end
             end)
    end

    test "a worker sees every provider's read operations, as for Slack",
         %{tenant: tenant, group_id: group_id} do
      {:ok, worker} =
        create_control_agent(
          %{"name" => "Worker", "group_id" => group_id, "role" => "worker"},
          tenant
        )

      for provider <- SalixIM.Provider.Manuals.external_providers() do
        {:ok, full} = SalixIM.Provider.Manuals.manual(provider)
        reads = for %{"name" => name, "safety" => "read"} <- full["apis"], do: name

        case SalixIM.Provider.provider_manual(provider, worker["agent_id"]) do
          {:ok, manual} ->
            names = Enum.map(manual["apis"], & &1["name"])
            assert reads -- names == [], "#{provider} hides reads from workers"

          {:error, :unsupported} ->
            assert reads == [], "#{provider} has reads but is hidden from workers"
        end
      end
    end

    test "worker cannot call external WeChat connects", %{tenant: tenant, group_id: group_id} do
      {:ok, worker} =
        create_control_agent(
          %{"name" => "Worker", "group_id" => group_id, "role" => "worker"},
          tenant
        )

      seed_connect(group_id, "wx-worker-denied", "wechat", %{
        "tenant_id" => tenant,
        "status" => "connected",
        "wechat_id" => "wx-denied",
        "base_url" => "https://wechat.example",
        "token" => "wx-token"
      })

      assert {:error, "connect not found"} =
               call(worker["agent_id"], "wechat", "wechat.reply_text", "wx-worker-denied", %{
                 "text" => "hi"
               })
    end

    test "disabled wechat connects are not callable",
         %{tenant: tenant, group_id: group_id, agent_id: agent_id} do
      seed_connect(group_id, "wx-disabled", "wechat", %{
        "tenant_id" => tenant,
        "status" => "connected",
        "wechat_id" => "wx-2",
        "base_url" => "https://wechat.example",
        "token" => "wx-token",
        "disabled_at" => 123
      })

      assert {:error, "connect not found"} =
               call(agent_id, "wechat", "wechat.reply_text", "wx-disabled", %{"text" => "hi"})
    end
  end

  test "conversation append preserves concurrent messages through CAS merge", %{
    group_id: group_id,
    agent_id: agent_id
  } do
    conv = seed_group_conversation(group_id, agent_id, %{"title" => "CAS"})
    cid = conv["conversation_id"]

    1..30
    |> SystemsClock.async_stream(
      fn n ->
        ConversationServer.append_group_conversation_message(group_id, cid, %{
          "client_request_id" => "cas-#{n}",
          "content" => [%{"type" => "text", "text" => "message #{n}"}]
        })
      end,
      max_concurrency: 30,
      timeout: :infinity
    )
    |> Enum.each(fn
      {:ok, {:ok, %{"inserted" => true}}} -> :ok
      other -> flunk("unexpected append result: #{inspect(other)}")
    end)

    {:ok, messages} = Conversations.list_group_conversation_messages(group_id, cid, limit: 100)

    assert length(messages) == 30
    assert Enum.all?(messages, &Ids.valid_message_id?(&1["message_id"]))

    assert messages
           |> Enum.map(& &1["client_request_id"])
           |> MapSet.new() == MapSet.new(Enum.map(1..30, &"cas-#{&1}"))
  end

  defp seed_triage_slack_connect(group_id, tenant, _label, secret) do
    seed_connect(group_id, Ids.new_connect_id(), "slack", %{
      "tenant_id" => tenant,
      "app_id" => "A1",
      "signing_secret" => secret,
      "workspace_id" => "T1",
      "bot_token" => "xoxb-test",
      "bot_id" => "B1",
      "bot_user_id" => "Ubot",
      "oauth_completed_at" => 1
    })
  end

  defp enable_explicit_slack_ingress!(connect, approved_channel_id) do
    MockSlack.respond("conversations.info", %{
      "ok" => true,
      "channel" => %{"id" => approved_channel_id, "name" => "triage"}
    })

    assert {:ok, _provisioned} =
             SalixIM.ProviderConnects.provision_slack_triage_authority(
               connect["tenant_id"],
               connect["group_id"],
               connect["connect_id"],
               approved_channel_id
             )

    assert :ok =
             SalixIM.ProviderConnects.set_slack_triage_enabled(
               connect["tenant_id"],
               connect["group_id"],
               connect["connect_id"],
               true
             )

    assert {:ok, current} =
             SalixStore.CasRecord.get(
               Keys.ctl_im_connect(connect["group_id"], connect["connect_id"])
             )

    current
  end

  test "Task-bound Slack threads bypass provisioned Triage routing", %{
    tenant: tenant,
    group_id: group_id,
    agent_id: router_id
  } do
    previous_delivery = SystemsRuntime.get_env(:salix_im, :agent_delivery_mod)
    SystemsRuntime.put_env(:salix_im, :agent_delivery_mod, FakeAgentDelivery)
    SystemsRuntime.put_env(:salix_im, :fake_agent_delivery_test_pid, SystemsRuntime.Proc.self())

    on_exit(fn ->
      restore(:salix_im, :agent_delivery_mod, previous_delivery)
      SystemsRuntime.delete_env(:salix_im, :fake_agent_delivery_test_pid)
    end)

    secret = "task-thread-provisioned-secret"
    channel_id = "C-task-thread-provisioned"
    thread_ts = "1787021764.000100"

    connect =
      group_id
      |> seed_triage_slack_connect(tenant, "task-thread-provisioned", secret)
      |> enable_explicit_slack_ingress!(channel_id)

    {conversation_id, worker_id} =
      create_slack_task!(tenant, group_id, router_id, "Own a provisioned Slack thread")

    settle_receive({:agent_delivery, ^worker_id, _initial_task_payload, _initial_task_opts})

    put_conversation_links_config(
      tenant,
      "https://teams.example.test/tasks/{tenant_id}/{group_id}/{conversation_id}"
    )

    MockSlack.respond("chat.postMessage", %{
      "ok" => true,
      "channel" => channel_id,
      "ts" => "1787021764.000200"
    })

    assert {:ok,
            %{
              "conversation_id" => ^conversation_id,
              "participant_id" => participant_id,
              "binding_status" => "created"
            }} =
             call(
               router_id,
               "slack",
               "slack.bind_thread_to_task",
               connect["connect_id"],
               %{
                 "conversation_id" => conversation_id,
                 "channel" => channel_id,
                 "thread_ts" => thread_ts
               }
             )

    [
      {"Ev-task-thread-provisioned-plain", nil,
       "An unmentioned provisioned reply belongs to the Task.", "1787021764.000300"},
      {"Ev-task-thread-provisioned-broadcast", "thread_broadcast",
       "A provisioned broadcast reply belongs to the Task.", "1787021764.000400"}
    ]
    |> Enum.each(fn {event_id, subtype, text, message_ts} ->
      event = %{
        "type" => "message",
        "user" => "U-provisioned-requester",
        "text" => text,
        "channel" => channel_id,
        "channel_type" => "channel",
        "ts" => message_ts,
        "thread_ts" => thread_ts
      }

      event = if is_nil(subtype), do: event, else: Map.put(event, "subtype", subtype)

      envelope = slack_envelope(event_id, event)
      raw = Jason.encode!(envelope)

      assert {:ok, :accepted} =
               SalixIM.ProviderHTTP.handle_slack_event(
                 connect,
                 envelope,
                 sign_slack_body(raw, secret),
                 raw
               )

      source_message_id = "im_provider:slack:#{connect["connect_id"]}:#{event_id}"

      assert eventually(fn ->
               case Conversations.list_group_conversation_messages(
                      group_id,
                      conversation_id,
                      limit: 20
                    ) do
                 {:ok, messages} ->
                   Enum.any?(messages, fn message ->
                     message["source_message_id"] == source_message_id and
                       message["participant_id"] == participant_id and
                       SalixIM.ConversationMessage.text_content(message["content"]) == text
                   end)

                 _ ->
                   false
               end
             end)

      settle_receive({:agent_delivery, ^worker_id, delivered, _delivery_opts})
      assert delivered.content == text
    end)
  end

  test "another app's reply reaches the Router Session before a later human command",
       %{tenant: tenant, group_id: group_id, agent_id: agent_id} do
    previous_delivery = SystemsRuntime.get_env(:salix_im, :agent_delivery_mod)
    SystemsRuntime.put_env(:salix_im, :agent_delivery_mod, FakeAgentDelivery)
    SystemsRuntime.put_env(:salix_im, :fake_agent_delivery_test_pid, SystemsRuntime.Proc.self())

    on_exit(fn ->
      restore(:salix_im, :agent_delivery_mod, previous_delivery)
      SystemsRuntime.delete_env(:salix_im, :fake_agent_delivery_test_pid)
    end)

    secret = "slack-directed-agent-context-secret"
    channel_id = "C0DIRECTEDCONTEXT"
    root_ts = "1788148287.418099"

    connect =
      group_id
      |> seed_triage_slack_connect(tenant, "sl-directed-agent-context", secret)
      |> enable_explicit_slack_ingress!(channel_id)

    root =
      slack_envelope("Ev-directed-context-root", %{
        "type" => "app_mention",
        "user" => "U0HUMANROOT",
        "text" => "<@Ubot> 这不是有吗",
        "channel" => channel_id,
        "channel_type" => "channel",
        "ts" => root_ts
      })

    root_raw = Jason.encode!(root)

    assert {:ok, :accepted} =
             SalixIM.ProviderHTTP.handle_slack_event(
               connect,
               root,
               sign_slack_body(root_raw, secret),
               root_raw
             )

    settle_receive({:agent_delivery, ^agent_id, root_payload, root_opts})
    refute root_opts[:no_wake]

    scope = %{
      "tenant_id" => tenant,
      "group_id" => group_id,
      "connect_id" => connect["connect_id"],
      "connect_generation" => connect["connect_generation"],
      "workspace_id" => connect["workspace_id"],
      "channel_id" => channel_id,
      "root_thread_ts" => root_ts
    }

    assert SalixIM.Provider.Slack.ThreadRouteOwner.lookup(scope) == {:ok, :legacy}

    peer_agent_text = "<@Ubot> source thread has the full meeting and Mafuzhen action items"

    peer_agent =
      slack_envelope("Ev-peer-agent-reply", %{
        "type" => "app_mention",
        "user" => "U0PEERAGENT",
        "bot_id" => "B0PEERAGENT",
        "app_id" => "A0PEERAGENT",
        "text" => peer_agent_text,
        "channel" => channel_id,
        "channel_type" => "channel",
        "ts" => "1788149000.000001",
        "thread_ts" => root_ts
      })

    peer_agent_raw = Jason.encode!(peer_agent)

    assert {:ok, :accepted} =
             SalixIM.ProviderHTTP.handle_slack_event(
               connect,
               peer_agent,
               sign_slack_body(peer_agent_raw, secret),
               peer_agent_raw
             )

    # Another app answering inside this command thread is ordinary input, not
    # inert context: the Router wakes on it the way it does for a person.
    settle_receive({:agent_delivery, ^agent_id, peer_payload, peer_opts})
    refute peer_opts[:no_wake]

    # App-authored messages carry the physical channel/ts identity, so a Slack
    # redelivery of the same message stays one delivery.
    assert peer_opts[:source_message_id] ==
             "im_provider:slack:#{connect["connect_id"]}:#{channel_id}:1788149000.000001"

    assert peer_payload.session_id == root_payload.session_id
    assert peer_payload.content =~ "source thread has the full meeting"
    assert peer_payload.trusted_origin["source_actor_type"] == "provider_system"
    assert peer_payload.trusted_origin["provider_context"]["app_authored"] == true
    assert SalixIM.Provider.Slack.ThreadRouteOwner.lookup(scope) == {:ok, :legacy}

    assert {:ok, :duplicate} =
             SalixIM.ProviderHTTP.handle_slack_event(
               connect,
               peer_agent,
               sign_slack_body(peer_agent_raw, secret),
               peer_agent_raw
             )

    settle_refute_receive({:agent_delivery, ^agent_id, _, _}, 100)

    follow_up =
      slack_envelope("Ev-directed-context-follow-up", %{
        "type" => "app_mention",
        "user" => "U0HUMANFOLLOWUP",
        "text" => "<@Ubot> 今天我需要做哪些东西",
        "channel" => channel_id,
        "channel_type" => "channel",
        "ts" => "1788149383.655599",
        "thread_ts" => root_ts
      })

    follow_up_raw = Jason.encode!(follow_up)

    assert {:ok, :accepted} =
             SalixIM.ProviderHTTP.handle_slack_event(
               connect,
               follow_up,
               sign_slack_body(follow_up_raw, secret),
               follow_up_raw
             )

    settle_receive({:agent_delivery, ^agent_id, follow_up_payload, follow_up_opts})
    assert follow_up_payload.session_id == peer_payload.session_id
    assert follow_up_payload.content =~ "今天我需要做哪些东西"
    refute follow_up_opts[:no_wake]
    refute Map.has_key?(follow_up_payload, :pre_deliveries)
    assert SalixIM.Provider.Slack.ThreadRouteOwner.lookup(scope) == {:ok, :legacy}
    assert MockSlack.requests("conversations.replies") == []
  end

  test "Slack inbound stages a text and image mention and reports an unstaged sibling",
       %{tenant: tenant, group_id: group_id, agent_id: agent_id} do
    SystemsRuntime.put_env(:salix_im, :agent_delivery_mod, FakeAgentDelivery)
    SystemsRuntime.put_env(:salix_im, :fake_agent_delivery_test_pid, SystemsRuntime.Proc.self())
    on_exit(fn -> SystemsRuntime.delete_env(:salix_im, :fake_agent_delivery_test_pid) end)

    secret = "slack-text-image-secret"
    channel_id = "C-text-image"

    connect =
      group_id
      |> seed_triage_slack_connect(tenant, "sl-text-image", secret)
      |> enable_explicit_slack_ingress!(channel_id)

    api_base = SystemsRuntime.fetch_env!(:salix_im, :slack_api_base_url)
    download_base = String.replace_suffix(api_base, "/api", "")
    MockSlack.respond("canvas_download", @png)

    envelope =
      slack_envelope("Ev-text-image", %{
        "type" => "app_mention",
        "user" => "U-human",
        "text" => "<@Ubot> what is this?",
        "channel" => channel_id,
        "channel_type" => "channel",
        "ts" => "1787907482.084839",
        "files" => [
          %{
            "id" => "F-text-image",
            "name" => "image.png",
            "mimetype" => "image/png",
            "size" => byte_size(@png),
            "url_private_download" => "#{download_base}/files/F-text-image"
          },
          %{
            "id" => "F-missing-url",
            "name" => "missing.png",
            "mimetype" => "image/png",
            "size" => 42
          }
        ]
      })

    raw = Jason.encode!(envelope)

    assert {:ok, :accepted} =
             SalixIM.ProviderHTTP.handle_slack_event(
               connect,
               envelope,
               sign_slack_body(raw, secret),
               raw
             )

    staged_path =
      SalixIM.SlackFiles.vfs_path(channel_id, "1787907482.084839", %{
        "id" => "F-text-image",
        "name" => "image.png"
      })

    settle_receive({:agent_delivery, ^agent_id, payload, opts})

    assert [
             %{"type" => "text", "text" => text},
             %{
               "type" => "image",
               "file_ref" => %{"environment_id" => "vfs", "path" => ^staged_path},
               "file_name" => "image.png",
               "mime_type" => "image/png"
             } = image,
             %{"type" => "text", "text" => attachment_failure}
           ] = Jason.decode!(payload.content)

    assert text =~ "what is this?"
    assert attachment_failure =~ "provider_attachment_error"
    assert attachment_failure =~ "missing.png"
    assert attachment_failure =~ "missing_download_url"
    assert payload.trusted_attachment_refs == [image]

    assert opts[:source_message_id] ==
             "im_provider:slack:#{connect["connect_id"]}:#{envelope["event_id"]}"

    assert {:ok, %{data: @png}} =
             SalixIM.Ports.AgentWorkspace.read_upload(agent_id, staged_path)

    assert {:ok, :duplicate} =
             SalixIM.ProviderHTTP.handle_slack_event(
               connect,
               envelope,
               sign_slack_body(raw, secret),
               raw
             )

    settle_refute_receive({:agent_delivery, ^agent_id, _, _}, 100)
  end

  test "Slack inbound delivers a human App Home DM across legacy and Triage connects",
       %{tenant: tenant, group_id: group_id, agent_id: agent_id} do
    SystemsRuntime.put_env(:salix_im, :agent_delivery_mod, FakeAgentDelivery)
    SystemsRuntime.put_env(:salix_im, :fake_agent_delivery_test_pid, SystemsRuntime.Proc.self())
    on_exit(fn -> SystemsRuntime.delete_env(:salix_im, :fake_agent_delivery_test_pid) end)

    secret = "slack-app-home-secret"

    connects = [
      {"legacy", seed_slack_inbound_connect(group_id, tenant, "sl-app-home-legacy", secret)},
      {"triage",
       group_id
       |> seed_triage_slack_connect(tenant, "sl-app-home-triage", secret)
       |> enable_explicit_slack_ingress!("C-approved")}
    ]

    for {label, connect} <- connects do
      event_id = "Ev-app-home-dm-#{label}"

      envelope =
        slack_envelope(event_id, %{
          "type" => "message",
          "user" => "U-human",
          "text" => "hello from App Home #{label}",
          "channel" => "D-app-home-#{label}",
          "channel_type" => "im",
          "ts" => "1787021764.000150"
        })

      raw = Jason.encode!(envelope)

      assert {:ok, :accepted} =
               SalixIM.ProviderHTTP.handle_slack_event(
                 connect,
                 envelope,
                 sign_slack_body(raw, secret),
                 raw
               )

      settle_receive({:agent_delivery, ^agent_id, payload, opts})
      assert payload.content =~ "hello from App Home #{label}"

      assert opts[:source_message_id] ==
               "im_provider:slack:#{connect["connect_id"]}:#{event_id}"
    end
  end

  defp seed_slack_inbound_connect(group_id, tenant, _label, secret) do
    seed_connect(group_id, Ids.new_connect_id(), "slack", %{
      "tenant_id" => tenant,
      "app_id" => "A1",
      "signing_secret" => secret,
      "workspace_id" => "T1",
      "bot_token" => "xoxb-test",
      "bot_user_id" => "Ubot",
      "oauth_completed_at" => 1
    })
  end

  defp slack_envelope(event_id, event) do
    %{
      "type" => "event_callback",
      "api_app_id" => "A1",
      "team_id" => "T1",
      "event_id" => event_id,
      "event" => event
    }
  end

  test "Slack source drives Router internal Task creation then explicit native Task-card publication",
       %{
         tenant: tenant,
         group_id: group_id,
         agent_id: router_id
       } do
    previous_task_mod = SystemsRuntime.get_env(:salix_im, :task_create_mod)
    previous_im_provider = SystemsRuntime.get_env(:salix_agent, :im_provider_mod)
    previous_llm = SystemsRuntime.get_env(:salix_agent, :llm)

    on_exit(fn ->
      RouterTaskCardLLM.clear()
      restore(:salix_im, :task_create_mod, previous_task_mod)
      restore(:salix_agent, :im_provider_mod, previous_im_provider)
      restore(:salix_agent, :llm, previous_llm)
    end)

    {:ok, worker} =
      create_control_agent(
        %{"name" => "Router card worker", "group_id" => group_id, "role" => "worker"},
        tenant
      )

    secret = "slack-router-card-secret"
    connect = seed_slack_inbound_connect(group_id, tenant, "sl-router-card", secret)
    marker = "ROUTER_TASK_CARD_E2E_#{SystemsRuntime.Proc.unique_integer([:positive])}"

    RouterTaskCardLLM.configure(%{
      marker: marker,
      worker_id: worker["agent_id"],
      connect_id: connect["connect_id"],
      channel: "C-router-card",
      thread_ts: "61.100"
    })

    SystemsRuntime.put_env(
      :salix_im,
      :task_create_mod,
      Salix.Bindings.AgentConversations
    )

    SystemsRuntime.put_env(:salix_agent, :im_provider_mod, Salix.Bindings.AgentIMProvider)
    SystemsRuntime.put_env(:salix_agent, :llm, RouterTaskCardLLM)

    MockSlack.respond("chat.postMessage", %{
      "ok" => true,
      "channel" => "C-router-card",
      "ts" => "61.200"
    })

    envelope =
      slack_envelope("Ev-router-task-card", %{
        "type" => "app_mention",
        "user" => "U-requester",
        "text" => "<@Ubot> delegate #{marker}",
        "channel" => "C-router-card",
        "channel_type" => "channel",
        "ts" => "61.100"
      })

    raw = Jason.encode!(envelope)

    assert {:ok, :accepted} =
             SalixIM.ProviderHTTP.handle_slack_event(
               connect,
               envelope,
               sign_slack_body(raw, secret),
               raw
             )

    assert eventually(fn -> length(MockSlack.requests("chat.postMessage")) == 1 end, 1200)

    [post_request] = MockSlack.requests("chat.postMessage")
    card = slack_task_card_from_request(post_request)

    assert post_request.params["channel"] == "C-router-card"
    assert post_request.params["thread_ts"] == "61.100"
    assert card["title"] == "Repository health report"

    assert {:ok, %{"data" => conversations}} =
             Conversations.list_group_conversations(group_id, limit: 100)

    assert [task] = Enum.filter(conversations, &(&1["kind"] == "agent_task"))
    assert task["created_by_agent_id"] == router_id
    assert task["task_worker_agent_id"] == worker["agent_id"]

    assert eventually(fn ->
             participant = task_card_participant!(group_id, task["conversation_id"])
             get_in(participant, ["payload", "message_ts"]) == "61.200"
           end)

    {:ok, router_session_id} =
      SalixIM.ProviderConnects.agent_group_router_session_id(router_id, group_id)

    assert eventually(fn ->
             case SalixAgent.TestSupport.SessionData.read(router_id, router_session_id) do
               {:ok, session} ->
                 called_tools =
                   for message <- session.messages,
                       call <- Map.get(message, :tool_calls) || [],
                       tool = get_in(call, ["args", "tool"]),
                       is_binary(tool),
                       do: tool

                 "im_api.internal.task.create" in called_tools and
                   "im_api.slack.post_task_card" in called_tools

               _ ->
                 false
             end
           end)
  end

  test "Feishu source drives Router internal Task creation and its automatic native Task card",
       %{
         tenant: tenant,
         group_id: group_id,
         agent_id: router_id
       } do
    previous_task_mod = SystemsRuntime.get_env(:salix_im, :task_create_mod)
    previous_im_provider = SystemsRuntime.get_env(:salix_agent, :im_provider_mod)
    previous_llm = SystemsRuntime.get_env(:salix_agent, :llm)
    previous_base_url = SystemsRuntime.get_env(:salix_im, :feishu_api_base_url)

    on_exit(fn ->
      RouterTaskCardLLM.clear()
      restore(:salix_im, :task_create_mod, previous_task_mod)
      restore(:salix_agent, :im_provider_mod, previous_im_provider)
      restore(:salix_agent, :llm, previous_llm)
      restore(:salix_im, :feishu_api_base_url, previous_base_url)
    end)

    start_supervised!(MockProviderRuntime)
    base_url = BanditServer.serve!(MockProviderRuntime)
    SystemsRuntime.put_env(:salix_im, :feishu_api_base_url, "#{base_url}/open-apis")

    {:ok, worker} =
      create_control_agent(
        %{"name" => "Feishu card worker", "group_id" => group_id, "role" => "worker"},
        tenant
      )

    connect =
      seed_connect(group_id, "fs-router-card", "feishu", %{
        "tenant_id" => tenant,
        "app_id" => "cli_card",
        "app_secret" => "feishu-card-secret",
        "verification_token" => "verify-token",
        "bot_open_id" => "ou_bot",
        "status" => "connected"
      })

    marker = "FEISHU_TASK_CARD_E2E_#{SystemsRuntime.Proc.unique_integer([:positive])}"

    RouterTaskCardLLM.configure(%{
      marker: marker,
      worker_id: worker["agent_id"],
      connect_id: connect["connect_id"],
      channel: nil,
      thread_ts: nil
    })

    SystemsRuntime.put_env(:salix_im, :task_create_mod, Salix.Bindings.AgentConversations)
    SystemsRuntime.put_env(:salix_agent, :im_provider_mod, Salix.Bindings.AgentIMProvider)
    SystemsRuntime.put_env(:salix_agent, :llm, RouterTaskCardLLM)

    MockProviderRuntime.feishu_messages([
      %{"message_id" => "om_card_source", "chat_id" => "oc_card", "msg_type" => "text"}
    ])

    MockProviderRuntime.feishu_reply_response(200, %{
      "code" => 0,
      "msg" => "ok",
      "data" => %{"message_id" => "om_task_card", "chat_id" => "oc_card"}
    })

    envelope = %{
      "schema" => "2.0",
      "header" => %{"token" => "verify-token", "app_id" => "cli_card"},
      "event" => %{
        "sender" => %{"sender_id" => %{"open_id" => "ou_requester"}, "sender_type" => "user"},
        "message" => %{
          "message_id" => "om_card_source",
          "chat_id" => "oc_card",
          "chat_type" => "group",
          "message_type" => "text",
          "mentions" => [
            %{"key" => "@_user_1", "id" => %{"open_id" => "ou_bot"}, "name" => "Bridge"}
          ],
          "content" => Jason.encode!(%{"text" => "@_user_1 delegate #{marker}"})
        }
      }
    }

    assert {:ok, %{ok: true, status: "queued"}} =
             SalixIM.ProviderHTTP.handle_feishu_event(
               connect,
               envelope,
               [],
               Jason.encode!(envelope)
             )

    assert eventually(
             fn ->
               Enum.any?(
                 MockProviderRuntime.requests(:feishu_reply),
                 &(&1.params["msg_type"] == "interactive")
               )
             end,
             1200
           )

    [card_reply] =
      Enum.filter(
        MockProviderRuntime.requests(:feishu_reply),
        &(&1.params["msg_type"] == "interactive")
      )

    card = Jason.decode!(card_reply.params["content"])
    assert card_reply.message_id == "om_card_source"
    assert card_reply.params["reply_in_thread"] == true
    assert get_in(card, ["header", "title", "content"]) == "Repository health report"

    assert {:ok, %{"data" => conversations}} =
             Conversations.list_group_conversations(group_id, limit: 100)

    assert [task] = Enum.filter(conversations, &(&1["kind"] == "agent_task"))
    assert task["created_by_agent_id"] == router_id

    assert eventually(fn ->
             feishu_task_card_participant!(group_id, task["conversation_id"])["payload"][
               "card_message_id"
             ] == "om_task_card"
           end)
  end

  test "Slack app_mention naming another bot cannot wake the connected Worker", %{
    tenant: tenant,
    group_id: group_id
  } do
    previous_delivery = SystemsRuntime.get_env(:salix_im, :agent_delivery_mod)
    previous_meeting = SystemsRuntime.get_env(:salix_im, :meeting_provider_handler)
    parent = SystemsRuntime.Proc.self()

    SystemsRuntime.put_env(:salix_im, :agent_delivery_mod, FakeAgentDelivery)
    SystemsRuntime.put_env(:salix_im, :fake_agent_delivery_test_pid, SystemsRuntime.Proc.self())

    SystemsRuntime.put_env(:salix_im, :meeting_provider_handler, fn _connect, _envelope ->
      SystemsRuntime.Proc.send(parent, :misdirected_app_mention_reached_meeting_handler)
      {:ok, :handled}
    end)

    on_exit(fn ->
      restore(:salix_im, :agent_delivery_mod, previous_delivery)
      restore(:salix_im, :meeting_provider_handler, previous_meeting)
      SystemsRuntime.delete_env(:salix_im, :fake_agent_delivery_test_pid)
    end)

    {:ok, worker} =
      create_control_agent(
        %{"name" => "Mention-isolated Slack worker", "group_id" => group_id, "role" => "worker"},
        tenant
      )

    secret = "slack-worker-mention-isolation-secret"

    connect =
      seed_connect(group_id, Ids.new_connect_id(), "slack", %{
        "tenant_id" => tenant,
        "app_id" => "A-worker-mention-isolation",
        "signing_secret" => secret,
        "workspace_id" => "T1",
        "bot_token" => "xoxb-worker-mention-isolation",
        "bot_id" => "B-worker-mention-isolation",
        "bot_user_id" => "U-worker-mention-isolation",
        "oauth_completed_at" => 1,
        "inbound_agent_id" => worker["agent_id"]
      })

    envelope =
      slack_envelope("Ev-worker-other-bot-app-mention", %{
        "type" => "app_mention",
        "user" => "U-requester",
        "text" => "review <@U-another-agent> #898",
        "channel" => "C-worker-mention-isolation",
        "channel_type" => "channel",
        "ts" => "64.100"
      })

    raw = Jason.encode!(envelope)

    assert {:error, :ignored} =
             SalixIM.ProviderHTTP.handle_slack_event(
               connect,
               envelope,
               sign_slack_body(raw, secret),
               raw
             )

    settle_refute_receive(:misdirected_app_mention_reached_meeting_handler)

    assert {:ok, %{"data" => conversations}} =
             Conversations.list_group_conversations(group_id, limit: 1000)

    refute Enum.any?(conversations, &(&1["kind"] == "agent_task"))

    assert {:error, :not_found} =
             SalixStore.CasRecord.get(
               Keys.ctl_im_slack_thread_binding(
                 group_id,
                 connect["connect_id"],
                 "C-worker-mention-isolation",
                 "64.100"
               )
             )

    settle_refute_receive({:agent_delivery, _, _, _})
  end

  test "Slack OAuth completion stores workspace identity without onboarding the router agent", %{
    tenant: tenant,
    group_id: group_id,
    agent_id: agent_id
  } do
    connect =
      seed_connect(group_id, "sl-oauth-onboarding", "slack", %{
        "tenant_id" => tenant,
        "app_id" => "A-onboarding",
        "signing_secret" => "slack-secret",
        "oauth_state" => "state-onboarding",
        "oauth_completed_at" => 0
      })

    oauth = %{
      "bot_token" => "xoxb-onboarding",
      "bot_id" => "B-onboarding",
      "bot_user_id" => "Ubot",
      "bot_username" => "comma-onboarding-bot",
      "workspace_id" => "T-onboarding",
      "workspace_name" => "Onboarding Workspace",
      "enterprise_id" => "E-onboarding",
      "owner_user_id" => "U-owner"
    }

    assert {:ok, completed} =
             SalixIM.ProviderConnects.complete_slack_im_connect_oauth(connect, oauth)

    assert completed["workspace_id"] == "T-onboarding"
    assert completed["bot_id"] == "B-onboarding"
    assert completed["bot_username"] == "comma-onboarding-bot"

    {:ok, session_id} = SalixIM.ProviderConnects.agent_group_router_session_id(agent_id, group_id)
    assert {:error, :not_found} = SalixAgent.TestSupport.SessionData.read(agent_id, session_id)
  end

  # A legacy connect is a backfill candidate while any bot identity field is
  # missing; one auth.test fills and persists them and retires the candidate.
  for {name, suffix, seeded_bot_id?} <- [
        {"resolves and persists a legacy connect", "bot-id-backfill", false},
        {"includes a legacy connect missing only bot username", "bot-username-backfill", true}
      ] do
    @suffix suffix
    @seeded_bot_id seeded_bot_id?
    test "Slack bot identity backfill #{name}", %{tenant: tenant, group_id: group_id} do
      bot_id = "B-#{@suffix}"
      bot_user_id = "Ubot-#{@suffix}"
      bot_username = "comma-#{@suffix}-bot"
      bot_token = "xoxb-#{@suffix}"

      attrs =
        %{
          "tenant_id" => tenant,
          "app_id" => "A-#{@suffix}",
          "signing_secret" => "slack-secret",
          "workspace_id" => "T-#{@suffix}",
          "bot_token" => bot_token,
          "bot_user_id" => bot_user_id,
          "oauth_completed_at" => 1
        }
        |> then(&if(@seeded_bot_id, do: Map.put(&1, "bot_id", bot_id), else: &1))

      connect = seed_connect(group_id, "sl-#{@suffix}", "slack", attrs)

      MockSlack.respond("auth.test", %{
        "ok" => true,
        "bot_id" => bot_id,
        "user_id" => bot_user_id,
        "user" => bot_username,
        "team_id" => "T-#{@suffix}"
      })

      assert {:ok, %{candidates: candidates}} =
               SalixIM.ProviderConnects.list_slack_bot_identity_backfill_candidates()

      assert Enum.any?(candidates, &(&1["connect_id"] == connect["connect_id"]))

      assert {:ok, updated} = SalixIM.ProviderHTTP.backfill_slack_bot_identity(connect)
      assert updated["bot_id"] == bot_id
      assert updated["bot_user_id"] == bot_user_id
      assert updated["bot_username"] == bot_username

      assert {:ok, stored} =
               SalixStore.CasRecord.get(Keys.ctl_im_connect(group_id, connect["connect_id"]))

      assert stored["bot_id"] == bot_id
      assert stored["bot_username"] == bot_username

      assert {:ok, %{candidates: candidates}} =
               SalixIM.ProviderConnects.list_slack_bot_identity_backfill_candidates()

      refute Enum.any?(candidates, &(&1["connect_id"] == connect["connect_id"]))

      request = MockSlack.last_request("auth.test")
      assert request.auth == "Bearer #{bot_token}"
      assert request.params == %{}
    end
  end

  test "Slack bot identity backfill rejects a mismatched workspace", %{
    tenant: tenant,
    group_id: group_id
  } do
    connect =
      seed_connect(group_id, "sl-bot-id-backfill-mismatch", "slack", %{
        "tenant_id" => tenant,
        "workspace_id" => "T-expected",
        "bot_token" => "xoxb-mismatch",
        "bot_user_id" => "Ubot-expected",
        "oauth_completed_at" => 1
      })

    MockSlack.respond("auth.test", %{
      "ok" => true,
      "bot_id" => "B-other",
      "user_id" => "Ubot-expected",
      "team_id" => "T-other"
    })

    assert {:error, message} = SalixIM.ProviderHTTP.backfill_slack_bot_identity(connect)

    assert message =~ "workspace"

    assert {:ok, stored} =
             SalixStore.CasRecord.get(Keys.ctl_im_connect(group_id, connect["connect_id"]))

    refute Map.has_key?(stored, "bot_id")
  end

  test "Slack public channel creation tells the router agent to join once without posting", %{
    tenant: tenant,
    group_id: group_id,
    agent_id: agent_id
  } do
    secret = "slack-secret"

    connect = seed_slack_inbound_connect(group_id, tenant, "sl-channel-created", secret)

    # bot_id is authority, not presentation: the canonical record is the only
    # place ingress reads it from, so the backfill has to land there first.
    {:ok, connect} =
      SalixStore.CasRecord.update(
        Keys.ctl_im_connect(group_id, connect["connect_id"]),
        fn rec ->
          Map.merge(rec, %{
            "bot_id" => "B-channel-created",
            "bot_username" => "comma-channel-bot"
          })
        end
      )

    recipient_identity = %{
      "provider" => "slack",
      "display_name" => "comma-channel-bot",
      "username" => "comma-channel-bot",
      "user_id" => "Ubot",
      "bot_id" => "B-channel-created",
      "app_id" => "A1"
    }

    ChannelCreatedJoinLLM.configure(%{
      connect_id: connect["connect_id"],
      channel_id: "C-new"
    })

    SystemsRuntime.put_env(:salix_agent, :llm, ChannelCreatedJoinLLM)
    on_exit(&ChannelCreatedJoinLLM.clear/0)

    MockSlack.respond("conversations.join", %{
      "ok" => true,
      "channel" => %{"id" => "C-new", "name" => "product-launch", "is_member" => true}
    })

    envelope =
      slack_envelope("Ev-channel-created", %{
        "type" => "channel_created",
        "channel" => %{
          "id" => "C-new",
          "name" => "product-launch",
          "created" => 1_787_042_100,
          "creator" => "U-creator"
        }
      })

    raw = Jason.encode!(envelope)

    assert {:ok, :accepted} =
             SalixIM.ProviderHTTP.handle_slack_event(
               connect,
               envelope,
               sign_slack_body(raw, secret),
               raw
             )

    source_id =
      "im_provider:slack:#{connect["connect_id"]}:channel_created:C-new:Ev-channel-created"

    assert_router_session_delivery(tenant, group_id, agent_id, source_id, "C-new")
    assert_router_session_delivery(tenant, group_id, agent_id, source_id, "product-launch")

    assert eventually(fn -> length(MockSlack.requests("conversations.join")) == 1 end)

    [join_request] = MockSlack.requests("conversations.join")
    assert join_request.auth == "Bearer xoxb-test"
    assert join_request.params == %{"channel" => "C-new"}
    assert MockSlack.requests("chat.postMessage") == []

    assert {:ok, :duplicate} =
             SalixIM.ProviderHTTP.handle_slack_event(
               connect,
               envelope,
               sign_slack_body(raw, secret),
               raw
             )

    assert length(MockSlack.requests("conversations.join")) == 1

    {:ok, session_id} = SalixIM.ProviderConnects.agent_group_router_session_id(agent_id, group_id)
    {:ok, session} = SalixAgent.TestSupport.SessionData.read(agent_id, session_id)

    matching =
      Enum.filter(session.messages, fn msg ->
        to_string(Map.get(msg, :source_message_id) || Map.get(msg, "source_message_id") || "") ==
          source_id and msg.role == "user"
      end)

    assert [matching_message] = matching

    assert recipient_im_identity_from_context!(to_string(matching_message.content || "")) ==
             recipient_identity
  end

  test "Slack bot channel join sends one channel onboarding message to the router agent", %{
    tenant: tenant,
    group_id: group_id,
    agent_id: agent_id
  } do
    SalixAgent.LLM.Mock.script([{:final, "ack"}, {:final, "ack-again"}])
    secret = "slack-secret"
    connect = seed_slack_inbound_connect(group_id, tenant, "sl-channel-onboarding", secret)

    envelope =
      slack_envelope("Ev-channel-join", %{
        "type" => "member_joined_channel",
        "user" => "Ubot",
        "channel" => "C-intro",
        "channel_type" => "C",
        "team" => "T1",
        "inviter" => "U-inviter"
      })

    raw = Jason.encode!(envelope)

    assert {:ok, :accepted} =
             SalixIM.ProviderHTTP.handle_slack_event(
               connect,
               envelope,
               sign_slack_body(raw, secret),
               raw
             )

    source_id =
      "im_provider:slack:#{connect["connect_id"]}:channel_joined:C-intro:Ev-channel-join"

    assert_router_session_delivery(
      tenant,
      group_id,
      agent_id,
      source_id,
      "C-intro"
    )

    assert {:ok, :duplicate} =
             SalixIM.ProviderHTTP.handle_slack_event(
               connect,
               envelope,
               sign_slack_body(raw, secret),
               raw
             )

    {:ok, session_id} = SalixIM.ProviderConnects.agent_group_router_session_id(agent_id, group_id)
    {:ok, session} = SalixAgent.TestSupport.SessionData.read(agent_id, session_id)

    matching =
      Enum.filter(session.messages, fn msg ->
        to_string(Map.get(msg, :source_message_id) || Map.get(msg, "source_message_id") || "") ==
          source_id and msg.role == "user"
      end)

    assert length(matching) == 1
  end

  # Each ignored event must leave no receipt, so a later relevant retry is
  # still processed.
  for {name, connect_id, event_id, event} <- [
        {"Slack member_joined_channel for another user is ignored", "sl-human-join",
         "Ev-human-join",
         %{
           "type" => "member_joined_channel",
           "user" => "U-human",
           "channel" => "C-intro",
           "channel_type" => "C",
           "team" => "T1",
           "inviter" => "U-inviter"
         }},
        {"Slack inbound ignores an app mention authored by this connect", "sl-own-app",
         "Ev-own-app",
         %{
           "type" => "app_mention",
           "user" => "Ubot",
           "bot_id" => "B-own",
           "app_id" => "A1",
           "text" => "<@Ubot> loop",
           "channel" => "C1",
           "channel_type" => "channel",
           "ts" => "123.457"
         }},
        {"Slack inbound fails closed for a bot-id-only event before identity backfill",
         "sl-legacy-bot-id", "Ev-legacy-bot-id",
         %{
           "type" => "app_mention",
           "bot_id" => "B-unknown",
           "text" => "<@Ubot> should not loop",
           "channel" => "C1",
           "channel_type" => "channel",
           "ts" => "123.459"
         }},
        {"Slack inbound ignores an ordinary channel message that does not mention the bot",
         "sl-plain", "Ev-plain",
         %{
           "type" => "message",
           "user" => "U1",
           "text" => "ordinary channel message",
           "channel" => "C1",
           "channel_type" => "channel",
           "ts" => "123.456"
         }},
        {"Slack inbound ignores a message-event mention (handled via app_mention)", "sl-dup",
         "Ev-dup",
         %{
           "type" => "message",
           "user" => "U1",
           "text" => "<@Ubot> please help",
           "channel" => "C1",
           "channel_type" => "channel",
           "ts" => "123.456"
         }}
      ] do
    @connect_id connect_id
    @event_id event_id
    @event event
    test name, %{tenant: tenant, group_id: group_id} do
      secret = "slack-secret"
      connect = seed_slack_inbound_connect(group_id, tenant, @connect_id, secret)
      envelope = slack_envelope(@event_id, @event)
      raw = Jason.encode!(envelope)

      assert {:error, :ignored} =
               SalixIM.ProviderHTTP.handle_slack_event(
                 connect,
                 envelope,
                 sign_slack_body(raw, secret),
                 raw
               )

      assert fake_records_with_prefix("ctl/im_slack_event_receipts/#{connect["connect_id"]}/") ==
               %{}
    end
  end

  test "Slack inbound delivers a top-level bot mention to the group router session", %{
    tenant: tenant,
    group_id: group_id,
    agent_id: agent_id
  } do
    SystemsRuntime.put_env(:salix_im, :agent_delivery_mod, FakeAgentDelivery)
    SystemsRuntime.put_env(:salix_im, :fake_agent_delivery_test_pid, SystemsRuntime.Proc.self())
    on_exit(fn -> SystemsRuntime.delete_env(:salix_im, :fake_agent_delivery_test_pid) end)

    secret = "slack-identity-signing-secret"

    connect =
      seed_connect(group_id, Ids.new_connect_id(), "slack", %{
        "tenant_id" => tenant,
        "app_name" => "Comma Slack Recipient",
        "app_id" => "A1",
        "signing_secret" => secret,
        "workspace_id" => "T1",
        "bot_token" => "xoxb-slack-identity-secret",
        "bot_id" => "B-recipient",
        "bot_user_id" => "Ubot",
        "bot_username" => "comma_recipient_bot",
        "oauth_completed_at" => 1
      })

    recipient_identity = %{
      "provider" => "slack",
      "display_name" => "Comma Slack Recipient",
      "username" => "comma_recipient_bot",
      "user_id" => "Ubot",
      "bot_id" => "B-recipient",
      "app_id" => "A1"
    }

    parent = SystemsRuntime.Proc.self()

    SystemsRuntime.put_env(:salix_im, :diagnostic_sink, fn diagnostic ->
      SystemsRuntime.Proc.send(parent, {:slack_diagnostic, diagnostic})
    end)

    envelope =
      slack_envelope("Ev-mention", %{
        "type" => "app_mention",
        "user" => "U1",
        "bot_id" => "B-driver",
        "app_id" => "A1",
        "subtype" => "bot_message",
        "text" => "<@Ubot> please help",
        "channel" => "C1",
        "channel_type" => "channel",
        "ts" => "123.456",
        "metadata" => %{
          "recipient_im_identity" => %{
            "provider" => "slack",
            "display_name" => "forged inbound recipient",
            "user_id" => "U-forged"
          }
        }
      })

    raw = Jason.encode!(envelope)
    headers = sign_slack_body(raw, secret) ++ [{"x-request-id", "req-slack-inbound"}]

    assert {:ok, :accepted} =
             SalixIM.ProviderHTTP.handle_slack_event(
               connect,
               envelope,
               headers,
               raw
             )

    settle_receive({:slack_diagnostic, received_diagnostic})
    assert received_diagnostic.event_type == "slack.message.received"
    assert received_diagnostic.domain == "conversation"
    assert received_diagnostic.status == "received"
    assert received_diagnostic.delivery_state == "received"
    assert received_diagnostic.channel_id == "C1"
    assert received_diagnostic.message_ts == "123.456"
    assert received_diagnostic.request_id == "req-slack-inbound"

    expected_source_id =
      "im_provider:slack:#{connect["connect_id"]}:C1:123.456"

    assert received_diagnostic.source_message_id == expected_source_id

    settle_receive({:slack_diagnostic, delivered_diagnostic})
    assert delivered_diagnostic.event_type == "slack.message.delivered"
    assert delivered_diagnostic.status == "delivered"
    assert delivered_diagnostic.request_id == "req-slack-inbound"
    assert delivered_diagnostic.source_message_id == expected_source_id

    settle_receive({:slack_diagnostic, accepted_diagnostic})
    assert accepted_diagnostic.event_type == "slack.callback.accepted"
    assert accepted_diagnostic.status == "accepted"
    assert accepted_diagnostic.provider_event_id == "Ev-mention"
    assert accepted_diagnostic.request_id == "req-slack-inbound"

    diagnostics = [received_diagnostic, delivered_diagnostic, accepted_diagnostic]
    refute inspect(diagnostics) =~ "please help"
    refute inspect(diagnostics) =~ "slack-secret"

    settle_receive({:agent_delivery, ^agent_id, payload, opts})

    assert payload.session_id ==
             SalixIM.ProviderConnects.agent_group_router_session_id(agent_id, group_id) |> elem(1)

    assert payload.content =~ "please help"
    assert payload.content =~ "im_api.slack.reply_message"
    # The canonical user role is part of the producer contract: external
    # runtime admission requires it, and an external ROUTER is a legal
    # control-plane combination (#870 review round 3).
    assert payload.role == "user"

    assert payload.provider_reply_obligation == %{
             "provider" => "slack",
             "connect_id" => connect["connect_id"],
             "channel" => "C1",
             "thread_ts" => "123.456"
           }

    assert recipient_im_identity_from_context!(payload.content) == recipient_identity
    refute payload.content =~ "forged inbound recipient"
    refute payload.content =~ "U-forged"
    refute payload.content =~ "xoxb-slack-identity-secret"
    refute payload.content =~ "slack-identity-signing-secret"
    refute Map.has_key?(payload, :pre_deliveries)
    refute payload.content =~ "This is the Router's first entry"
    assert opts[:source_message_id] == expected_source_id

    assert MockSlack.requests("conversations.replies") == []

    assert {:ok, _conversation} =
             SalixIM.RouterConversationProjection.get_group_router_conversation(group_id)
  end

  test "an ambiguous Slack top-level write is verified by operation_ref before resend", %{
    tenant: tenant,
    group_id: group_id,
    agent_id: router_agent_id
  } do
    previous_grace = SystemsRuntime.get_env(:salix_im, :provider_verify_grace_ms)
    SystemsRuntime.put_env(:salix_im, :provider_verify_grace_ms, 200)

    on_exit(fn ->
      restore(:salix_im, :provider_verify_grace_ms, previous_grace)
    end)

    connect =
      seed_connect(group_id, Ids.new_connect_id(), "slack", %{
        "tenant_id" => tenant,
        "app_id" => "A-ambiguous-calendar",
        "workspace_id" => "T-ambiguous-calendar",
        "bot_token" => "xoxb-test",
        "bot_user_id" => "Ubot",
        "oauth_completed_at" => 1
      })

    conversation =
      seed_group_conversation(group_id, router_agent_id, %{
        "kind" => "agent_task",
        "title" => "Ambiguous Calendar preparation",
        "participants" => [
          %{
            "actor_type" => "agent",
            "agent_id" => router_agent_id,
            "state" => "active",
            "notification_filter" => %{"messages" => "all", "statuses" => "none"}
          }
        ]
      })

    assert {:ok, provider_participant} =
             ConversationServer.ensure_group_conversation_provider_participant(
               group_id,
               conversation["conversation_id"],
               %{
                 "actor_type" => "provider",
                 "provider" => "slack",
                 "target_key" => "ambiguous-calendar:#{connect["connect_id"]}:C-ambiguous",
                 "role_label" => "calendar_target",
                 "payload" => %{
                   "connect_id" => connect["connect_id"],
                   "workspace_id" => "T-ambiguous-calendar",
                   "channel_id" => "C-ambiguous"
                 },
                 "state" => "active",
                 "notification_filter" => %{"messages" => "all", "statuses" => "none"}
               }
             )

    MockSlack.respond("chat.postMessage", 500, %{"error" => "response lost"})

    assert {:ok, %{"inserted" => true} = message} =
             ConversationServer.append_group_conversation_agent_message(
               group_id,
               conversation["conversation_id"],
               router_agent_id,
               %{
                 "client_request_id" => "ambiguous-calendar-provisional",
                 "content" => "Provisional pre-meeting research briefing"
               }
             )

    assert eventually(fn -> length(MockSlack.requests("chat.postMessage")) == 1 end)

    [first_post] = MockSlack.requests("chat.postMessage")

    operation_ref =
      first_post.params["metadata"]
      |> Jason.decode!()
      |> get_in(["event_payload", "operation_ref"])

    MockSlack.respond("conversations.history", %{
      "ok" => true,
      "messages" => [
        %{
          "type" => "message",
          "ts" => "600.100",
          "metadata" => %{
            "event_type" => "salix_conversation_delivery",
            "event_payload" => %{"operation_ref" => operation_ref}
          }
        }
      ],
      "response_metadata" => %{"next_cursor" => ""}
    })

    assert eventually(fn ->
             Enum.any?(
               delivery_records(group_id, conversation["conversation_id"]) |> Map.values(),
               &(&1["participant_id"] == provider_participant["participant_id"] and
                   &1["message_id"] == message["message_id"] and &1["status"] == "delivered")
             )
           end)

    assert length(MockSlack.requests("chat.postMessage")) == 1
    assert [_history_request] = MockSlack.requests("conversations.history")
  end

  test "an omitted delivery filter targets every subscribed participant", %{
    tenant: tenant,
    group_id: group_id,
    agent_id: router_agent_id
  } do
    {:ok, worker} =
      create_control_agent(
        %{"name" => "Meeting research worker", "group_id" => group_id, "role" => "worker"},
        tenant
      )

    worker_agent_id = worker["agent_id"]

    conversation =
      seed_group_conversation(group_id, router_agent_id, %{
        "kind" => "agent_task",
        "title" => "Internal research boundary",
        "participants" => [
          %{
            "actor_type" => "agent",
            "agent_id" => router_agent_id,
            "state" => "active",
            "notification_filter" => %{"messages" => "all", "statuses" => "none"}
          },
          %{
            "actor_type" => "agent",
            "agent_id" => worker_agent_id,
            "state" => "active",
            "notification_filter" => %{"messages" => "all", "statuses" => "none"}
          }
        ]
      })

    assert {:ok, provider_participant} =
             ConversationServer.ensure_group_conversation_provider_participant(
               group_id,
               conversation["conversation_id"],
               %{
                 "actor_type" => "provider",
                 "provider" => "slack",
                 "target_key" => "calendar-internal-boundary",
                 "role_label" => "calendar_target",
                 "payload" => %{
                   "connect_id" => "slack-internal-boundary",
                   "workspace_id" => "T-internal",
                   "channel_id" => "C-internal"
                 },
                 "state" => "active",
                 "notification_filter" => %{"messages" => "all", "statuses" => "none"}
               }
             )

    assert {:ok, %{"participants" => participants}} =
             Conversations.list_group_conversation_participants(
               group_id,
               conversation["conversation_id"]
             )

    router_participant =
      Enum.find(participants, &(&1["agent_id"] == router_agent_id))

    worker_participant =
      Enum.find(participants, &(&1["agent_id"] == worker_agent_id))

    assert {:ok, %{"message_id" => _request_message_id}} =
             ConversationServer.append_group_conversation_agent_message(
               group_id,
               conversation["conversation_id"],
               router_agent_id,
               %{
                 "client_request_id" => "internal-research-request",
                 "content" => "Research this meeting",
                 "delivery_filter" => %{
                   "participant_ids" => [worker_participant["participant_id"]]
                 }
               }
             )

    assert {:ok, %{"message_id" => reply_message_id}} =
             ConversationServer.append_group_conversation_agent_message(
               group_id,
               conversation["conversation_id"],
               worker_agent_id,
               %{
                 "client_request_id" => "internal-research-checkpoint",
                 "content" => "Internal checkpoint"
               }
             )

    assert {:ok, reply} =
             Conversations.get_group_conversation_message(
               group_id,
               conversation["conversation_id"],
               reply_message_id
             )

    assert reply["delivery_filter"] == nil
    assert SalixIM.ConversationMessage.targets_participant?(router_participant, reply)
    assert SalixIM.ConversationMessage.targets_participant?(provider_participant, reply)

    assert {:ok, %{"message_id" => _publication_message_id}} =
             ConversationServer.append_group_conversation_agent_message(
               group_id,
               conversation["conversation_id"],
               router_agent_id,
               %{
                 "client_request_id" => "external-publication",
                 "content" => "Published briefing"
               }
             )

    assert {:ok, %{"message_id" => follow_up_message_id}} =
             ConversationServer.append_group_conversation_agent_message(
               group_id,
               conversation["conversation_id"],
               worker_agent_id,
               %{
                 "client_request_id" => "internal-post-publication-checkpoint",
                 "content" => "Post-publication internal checkpoint"
               }
             )

    assert {:ok, follow_up} =
             Conversations.get_group_conversation_message(
               group_id,
               conversation["conversation_id"],
               follow_up_message_id
             )

    assert follow_up["delivery_filter"] == nil
    assert SalixIM.ConversationMessage.targets_participant?(router_participant, follow_up)
    assert SalixIM.ConversationMessage.targets_participant?(provider_participant, follow_up)
  end

  test "Slack inbound bound to a worker creates and reuses task conversations", %{
    tenant: tenant,
    group_id: group_id,
    agent_id: router_agent_id
  } do
    secret = "slack-worker-identity-signing-secret"
    previous_placement = SystemsRuntime.get_env(:salix_im, :slack_router_status_placement)

    SystemsRuntime.put_env(
      :salix_im,
      :slack_router_status_placement,
      SalixIM.SlackRouterStatusPlacement.LocalFleet
    )

    on_exit(fn ->
      restore(:salix_im, :slack_router_status_placement, previous_placement)
    end)

    start_slack_status_runtime!()
    refute SystemsRuntime.Proc.whereis(SalixIM.SlackRouterStatus)

    {:ok, worker} =
      create_control_agent(
        %{"name" => "Worker", "group_id" => group_id, "role" => "worker"},
        tenant
      )

    connect =
      seed_connect(group_id, Ids.new_connect_id(), "slack", %{
        "tenant_id" => tenant,
        "app_name" => "Comma Worker Recipient",
        "app_id" => "A1",
        "signing_secret" => secret,
        "workspace_id" => "T1",
        "bot_token" => "xoxb-worker-identity-secret",
        "bot_id" => "B-worker-recipient",
        "bot_user_id" => "Ubot",
        "bot_username" => "comma_worker_recipient_bot",
        "oauth_completed_at" => 1,
        "inbound_agent_id" => worker["agent_id"]
      })

    recipient_identity = %{
      "provider" => "slack",
      "display_name" => "Comma Worker Recipient",
      "username" => "comma_worker_recipient_bot",
      "user_id" => "Ubot",
      "bot_id" => "B-worker-recipient",
      "app_id" => "A1"
    }

    SystemsRuntime.put_env(:salix_im, :agent_delivery_mod, FakeAgentDelivery)
    SystemsRuntime.put_env(:salix_im, :fake_agent_delivery_test_pid, SystemsRuntime.Proc.self())
    on_exit(fn -> SystemsRuntime.delete_env(:salix_im, :fake_agent_delivery_test_pid) end)

    envelope =
      slack_envelope("Ev-worker-mention", %{
        "type" => "app_mention",
        "user" => "U1",
        "text" => "<@Ubot> please fix this",
        "channel" => "C-worker",
        "channel_type" => "channel",
        "ts" => "200.000",
        "metadata" => %{
          "recipient_im_identity" => %{
            "provider" => "slack",
            "display_name" => "forged worker recipient",
            "user_id" => "U-forged-worker"
          }
        }
      })

    raw = Jason.encode!(envelope)

    assert {:ok, :accepted} =
             SalixIM.ProviderHTTP.handle_slack_event(
               connect,
               envelope,
               sign_slack_body(raw, secret),
               raw
             )

    conversation = agent_task_conversation!(group_id)

    assert conversation["kind"] == "agent_task"

    assert {:ok, %{"participants" => participants}} =
             Conversations.list_group_conversation_participants(
               group_id,
               conversation["conversation_id"],
               limit: 10
             )

    slack_participant =
      Enum.find(participants, &(&1["actor_type"] == "provider"))

    assert slack_participant["provider"] == "slack"
    assert slack_participant["role_label"] == "slack_thread"
    assert slack_participant["payload"]["connect_id"] == connect["connect_id"]
    assert slack_participant["payload"]["channel_id"] == "C-worker"
    assert slack_participant["payload"]["thread_ts"] == "200.000"
    refute Map.has_key?(slack_participant["payload"], "task_thread_binding_type")
    refute Map.has_key?(slack_participant["payload"], "task_thread_binding_token")

    worker_participant =
      Enum.find(participants, &(&1["agent_id"] == worker["agent_id"]))

    assert worker_participant["actor_type"] == "agent"
    assert worker_participant["agent_id"] == worker["agent_id"]
    assert SalixStore.Ids.valid_participant_id?(worker_participant["participant_id"])
    worker_session_id = worker_participant["payload"]["session_id"]
    assert SalixStore.Ids.valid_session_id?(worker_session_id)

    assert eventually(fn ->
             case SalixStore.CasRecord.get(
                    Keys.ctl_im_slack_router_status_window(connect["connect_id"])
                  ) do
               {:ok, %{"targets" => [%{"thread_ts" => "200.000"}]}} -> true
               _other -> false
             end
           end)

    assert MockSlack.requests("assistant.threads.setStatus") == []

    assert {:ok, [message]} =
             Conversations.list_group_conversation_messages(
               group_id,
               conversation["conversation_id"],
               limit: 10
             )

    assert message["mentions"] == %{
             "participant_ids" => [worker_participant["participant_id"]]
           }

    assert message["actor_type"] == "provider_user"
    assert message["participant_id"] == slack_participant["participant_id"]
    assert message["user_id"] == "U1"
    assert message["metadata"]["provider"] == "slack"
    assert message["metadata"]["thread_ts"] == "200.000"
    refute Map.has_key?(message["metadata"], "recipient_im_identity")
    assert message["owner_recipient_im_identity_v1"] == recipient_identity
    assert SalixStore.Ids.valid_message_id?(message["message_id"])

    assert message["source_message_id"] ==
             "im_provider:slack:#{connect["connect_id"]}:Ev-worker-mention"

    first_message_id = message["message_id"]
    assert inspect(message["content"]) =~ "please fix this"

    assert {:ok, %{"messages" => [public_message]}} =
             call(worker["agent_id"], "internal", "internal.read_conversation", "internal", %{
               "conversation_id" => conversation["conversation_id"],
               "message_id" => first_message_id
             })

    assert public_message["message_id"] == first_message_id
    refute Map.has_key?(public_message, "owner_recipient_im_identity_v1")
    refute Map.has_key?(public_message, "metadata")

    settle_receive({:agent_delivery, delivered_agent_id, delivered_payload, _delivered_opts})
    assert delivered_agent_id == worker["agent_id"]
    assert delivered_payload.session_id == worker_session_id

    [first_source_context_delivery] = delivered_payload.pre_deliveries
    first_source_context = first_source_context_delivery.content
    [first_source_facts | _] = String.split(first_source_context, "\n\n", parts: 2)

    assert recipient_im_identity_from_context!(first_source_context) == recipient_identity

    for routing_field <- ["connect_id", "workspace_id", "channel_id", "thread_ts"] do
      refute first_source_facts =~ routing_field
    end

    for private_fragment <- [
          "xoxb-worker-identity-secret",
          "slack-worker-identity-signing-secret",
          "forged worker recipient",
          "U-forged-worker"
        ] do
      refute first_source_context =~ private_fragment
    end

    assert MockSlack.requests("chat.postMessage") == []

    {:ok, router_session_id} =
      SalixIM.ProviderConnects.agent_group_router_session_id(router_agent_id, group_id)

    assert {:error, :not_found} =
             SalixAgent.TestSupport.SessionData.read(router_agent_id, router_session_id)

    assert {:ok, :duplicate} =
             SalixIM.ProviderHTTP.handle_slack_event(
               connect,
               envelope,
               sign_slack_body(raw, secret),
               raw
             )

    assert {:ok, [%{"message_id" => ^first_message_id}]} =
             Conversations.list_group_conversation_messages(
               group_id,
               conversation["conversation_id"],
               limit: 10
             )

    MockSlack.respond("conversations.replies", %{
      "ok" => true,
      "messages" => [
        %{"type" => "message", "user" => "U1", "text" => "root", "ts" => "200.000"},
        %{"type" => "message", "user" => "Ubot", "text" => "bot reply", "ts" => "200.100"}
      ]
    })

    thread_envelope =
      slack_envelope("Ev-worker-thread", %{
        "type" => "message",
        "user" => "U2",
        "text" => "more details",
        "channel" => "C-worker",
        "channel_type" => "channel",
        "ts" => "200.200",
        "thread_ts" => "200.000",
        "metadata" => %{
          "recipient_im_identity" => %{
            "provider" => "slack",
            "display_name" => "second forged recipient",
            "user_id" => "U-second-forged"
          }
        }
      })

    thread_raw = Jason.encode!(thread_envelope)

    assert {:ok, :accepted} =
             SalixIM.ProviderHTTP.handle_slack_event(
               connect,
               thread_envelope,
               sign_slack_body(thread_raw, secret),
               thread_raw
             )

    assert MockSlack.requests("conversations.replies") == []

    assert {:ok, messages} =
             Conversations.list_group_conversation_messages(
               group_id,
               conversation["conversation_id"],
               limit: 10
             )

    assert length(messages) == 2

    second_user_message =
      Enum.find(
        messages,
        &(&1["source_message_id"] ==
            "im_provider:slack:#{connect["connect_id"]}:Ev-worker-thread")
      )

    assert SalixStore.Ids.valid_message_id?(second_user_message["message_id"])
    assert second_user_message["participant_id"] == slack_participant["participant_id"]
    assert second_user_message["actor_type"] == "provider_user"
    assert second_user_message["user_id"] == "U2"
    refute Map.has_key?(second_user_message["metadata"], "recipient_im_identity")
    assert second_user_message["owner_recipient_im_identity_v1"] == recipient_identity

    first_user_message = Enum.find(messages, &(&1["message_id"] == first_message_id))
    refute Map.has_key?(first_user_message["metadata"], "recipient_im_identity")
    assert first_user_message["owner_recipient_im_identity_v1"] == recipient_identity

    settle_receive(
      {:agent_delivery, second_delivered_agent_id, second_delivered_payload,
       _second_delivered_opts}
    )

    assert second_delivered_agent_id == worker["agent_id"]
    assert second_delivered_payload.session_id == worker_session_id

    [second_source_context_delivery] = second_delivered_payload.pre_deliveries
    second_source_context = second_source_context_delivery.content
    [second_source_facts | _] = String.split(second_source_context, "\n\n", parts: 2)

    assert recipient_im_identity_from_context!(second_source_context) == recipient_identity
    refute second_source_context =~ "second forged recipient"
    refute second_source_context =~ "U-second-forged"
    refute second_source_context =~ "xoxb-worker-identity-secret"

    for routing_field <- ["connect_id", "workspace_id", "channel_id", "thread_ts"] do
      refute second_source_facts =~ routing_field
    end

    MockSlack.respond("chat.postMessage", %{
      "ok" => true,
      "channel" => "C-worker",
      "ts" => "200.300"
    })

    assert {:ok, %{"inserted" => true} = worker_reply} =
             ConversationServer.append_group_conversation_agent_message(
               group_id,
               conversation["conversation_id"],
               worker["agent_id"],
               %{
                 "client_request_id" => "worker-visible-reply",
                 "content" => [%{"type" => "text", "text" => "I am working on it"}]
               }
             )

    worker_reply_message_id = worker_reply["message_id"]
    assert SalixStore.Ids.valid_message_id?(worker_reply_message_id)

    assert eventually(fn ->
             group_id
             |> delivery_records(conversation["conversation_id"])
             |> Map.values()
             |> Enum.any?(
               &(&1["participant_actor_type"] == "provider" and
                   &1["message_id"] == worker_reply_message_id)
             )
           end)

    provider_deliveries =
      group_id
      |> delivery_records(conversation["conversation_id"])
      |> Map.values()
      |> Enum.filter(
        &(&1["participant_actor_type"] == "provider" and
            &1["message_id"] == worker_reply_message_id)
      )

    assert [provider_delivery] = provider_deliveries
    assert provider_delivery["participant_payload"]["connect_id"] == connect["connect_id"]
    assert provider_delivery["participant_payload"]["channel_id"] == "C-worker"
    assert provider_delivery["participant_payload"]["thread_ts"] == "200.000"
    refute Map.has_key?(provider_delivery, "task_thread_binding_type")

    refute Map.has_key?(
             provider_delivery["participant_payload"],
             "task_thread_binding_type"
           )

    refute Map.has_key?(
             provider_delivery["participant_payload"],
             "task_thread_binding_token"
           )

    assert eventually(fn -> not is_nil(MockSlack.last_request("chat.postMessage")) end)
    slack_post = MockSlack.last_request("chat.postMessage")
    assert slack_post.params["channel"] == "C-worker"
    assert slack_post.params["thread_ts"] == "200.000"
    assert slack_post.params["text"] == "I am working on it"

    another_envelope =
      slack_envelope("Ev-worker-other-thread", %{
        "type" => "app_mention",
        "user" => "U3",
        "text" => "<@Ubot> separate task",
        "channel" => "C-worker",
        "channel_type" => "channel",
        "ts" => "300.000"
      })

    another_raw = Jason.encode!(another_envelope)

    assert {:ok, :accepted} =
             SalixIM.ProviderHTTP.handle_slack_event(
               connect,
               another_envelope,
               sign_slack_body(another_raw, secret),
               another_raw
             )

    assert {:ok, %{"data" => conversations}} =
             Conversations.list_group_conversations(group_id, limit: 10)

    assert length(Enum.filter(conversations, &(&1["kind"] == "agent_task"))) == 2
  end

  # A file_share reply in a thread the bot joined, with no @-mention, is staged
  # into the Router workspace whatever the file type or caption.
  for {name, connect_id, event_id, ts, text, file_id, file_name, mimetype, bytes} <- [
        {"an image shared in a thread the bot joined (file_share, no mention)", "sl-thread-img",
         "Ev-thread-img", "200.001", "看一下这张图，描述一下内容", "F2", "photo.png", "image/png", @png},
        {"a non-image file (e.g. video) shared in a thread the bot joined", "sl-thread-vid",
         "Ev-thread-vid", "300.002", "", "F3", "clip.mp4", "video/mp4",
         <<0x00, 0x00, 0x00, 0x18, "ftypmp42", "fake-mp4-bytes">>}
      ] do
    @connect_id connect_id
    @event_id event_id
    @bytes bytes
  end

  test "threaded Slack Router app mention seeds participation for the immediate unmentioned reply",
       %{
         tenant: tenant,
         group_id: group_id,
         agent_id: agent_id
       } do
    previous_delivery = SystemsRuntime.get_env(:salix_im, :agent_delivery_mod)
    SystemsRuntime.put_env(:salix_im, :agent_delivery_mod, FakeAgentDelivery)
    SystemsRuntime.put_env(:salix_im, :fake_agent_delivery_test_pid, SystemsRuntime.Proc.self())

    on_exit(fn ->
      restore(:salix_im, :agent_delivery_mod, previous_delivery)
      SystemsRuntime.delete_env(:salix_im, :fake_agent_delivery_test_pid)
    end)

    secret = "slack-secret"
    connect = seed_slack_inbound_connect(group_id, tenant, "sl-thread-mention-cache", secret)

    root = %{
      "type" => "message",
      "user" => "U0",
      "text" => "root",
      "ts" => "105.000000"
    }

    prior =
      1..12
      |> Enum.map(fn index ->
        %{
          "type" => "message",
          "user" => "U#{index}",
          "text" => "prior #{index}",
          "ts" => "105." <> String.pad_leading(Integer.to_string(index), 6, "0"),
          "thread_ts" => "105.000000"
        }
      end)
      |> List.update_at(8, fn message ->
        Map.put(message, "files", [
          %{
            "id" => "F-history",
            "name" => "evidence.pdf",
            "mimetype" => "application/pdf",
            "size" => 42,
            "url_private" => "https://private.example/evidence.pdf"
          }
        ])
      end)

    MockSlack.respond("conversations.replies", %{
      "ok" => true,
      # Slack time windows return the earliest messages first and never exceed
      # the requested limit. The first automatic page is therefore root + 1..9.
      "messages" => [root] ++ Enum.take(prior, 9),
      "has_more" => true,
      "response_metadata" => %{"next_cursor" => "MORE"}
    })

    mentioned =
      slack_envelope("Ev-thread-mention-cache", %{
        "type" => "app_mention",
        "user" => "U1",
        "text" => "<@Ubot> start helping in this thread",
        "channel" => "C-thread-mention-cache",
        "channel_type" => "channel",
        "ts" => "105.000013",
        "event_ts" => "999.000013",
        "thread_ts" => "105.000000"
      })

    mentioned_raw = Jason.encode!(mentioned)

    assert {:ok, :accepted} =
             SalixIM.ProviderHTTP.handle_slack_event(
               connect,
               mentioned,
               sign_slack_body(mentioned_raw, secret),
               mentioned_raw
             )

    assert [request] = MockSlack.requests("conversations.replies")
    assert request.auth == "Bearer xoxb-test"

    assert Map.take(request.params, [
             "channel",
             "ts",
             "latest",
             "inclusive",
             "include_all_metadata",
             "limit"
           ]) == %{
             "channel" => "C-thread-mention-cache",
             "ts" => "105.000000",
             "latest" => "105.000013",
             "inclusive" => "false",
             "include_all_metadata" => "true",
             "limit" => "10"
           }

    refute Enum.any?(request.params, fn {_key, value} -> value == "999.000013" end)

    first_source =
      "im_provider:slack:#{connect["connect_id"]}:Ev-thread-mention-cache"

    settle_receive({:agent_delivery, ^agent_id, first_payload, first_opts})
    assert first_opts[:source_message_id] == first_source

    assert first_payload.role == "user"

    assert first_payload.provider_reply_obligation == %{
             "provider" => "slack",
             "connect_id" => connect["connect_id"],
             "channel" => "C-thread-mention-cache",
             "thread_ts" => "105.000000"
           }

    assert [history_delivery] = first_payload.pre_deliveries
    refute Map.has_key?(history_delivery, :provider_reply_obligation)
    assert history_delivery["role"] == "user"
    assert history_delivery["source_message_id"] == first_source <> ":slack-thread-history"
    refute history_delivery["content"] =~ "https://private.example"

    history_json =
      history_delivery["content"]
      |> String.split("UNTRUSTED_SLACK_THREAD_HISTORY_JSON=", parts: 2)
      |> List.last()
      |> Jason.decode!()

    assert Enum.map(history_json["messages"], & &1["ts"]) ==
             ["105.000000"] ++
               Enum.map(
                 1..9,
                 &("105." <> String.pad_leading(Integer.to_string(&1), 6, "0"))
               )

    assert Enum.map(history_json["messages"], & &1["text"]) ==
             ["root"] ++ Enum.map(1..9, &"prior #{&1}")

    assert get_in(history_json, ["messages", Access.at(9), "files"]) == [
             %{
               "id" => "F-history",
               "name" => "evidence.pdf",
               "mimetype" => "application/pdf",
               "size" => 42
             }
           ]

    refute inspect(history_json) =~ "current"
    refute inspect(history_json) =~ "newer"
    refute inspect(history_json) =~ "private.example"

    assert first_payload.content =~ "start helping in this thread"
    assert first_payload.content =~ "message_ts=105.000013"
    assert first_payload.content =~ "event_ts=999.000013"

    assert first_payload.content =~
             "preceding untrusted Slack-history user delivery contains the first 10"

    assert first_payload.content =~ "im_api.slack.get_thread_replies"
    assert first_payload.content =~ "oldest=105.000009"
    assert first_payload.content =~ "latest=105.000013"
    assert first_payload.content =~ "inclusive=false"
    assert first_payload.content =~ "root_already_preloaded=true"
    assert first_payload.content =~ "limit=15"
    assert first_payload.content =~ "next_cursor"
    refute first_payload.content =~ "prior 12"

    assert SalixStore.SlackRouterThreadParticipations.participating?(
             group_id,
             connect["connect_id"],
             connect["workspace_id"],
             connect["bot_user_id"],
             "C-thread-mention-cache",
             "105.000000"
           )

    follow_up =
      slack_envelope("Ev-thread-mention-cache-follow-up", %{
        "type" => "message",
        "user" => "U2",
        "text" => "continue without another mention",
        "channel" => "C-thread-mention-cache",
        "channel_type" => "channel",
        "ts" => "105.000014",
        "event_ts" => "999.000014",
        "thread_ts" => "105.000000"
      })

    follow_up_raw = Jason.encode!(follow_up)

    assert {:ok, :accepted} =
             SalixIM.ProviderHTTP.handle_slack_event(
               connect,
               follow_up,
               sign_slack_body(follow_up_raw, secret),
               follow_up_raw
             )

    settle_receive({:agent_delivery, ^agent_id, second_payload, _second_opts})
    assert second_payload.content =~ "continue without another mention"
    assert second_payload.content =~ "message_ts=105.000014"
    refute Map.has_key?(second_payload, :pre_deliveries)
    refute second_payload.content =~ "This is the Router's first entry"

    mentioned_again =
      slack_envelope("Ev-thread-mention-cache-again", %{
        "type" => "app_mention",
        "user" => "U3",
        "text" => "<@Ubot> explicit follow up after joining",
        "channel" => "C-thread-mention-cache",
        "channel_type" => "channel",
        "ts" => "105.000015",
        "event_ts" => "999.000015",
        "thread_ts" => "105.000000"
      })

    mentioned_again_raw = Jason.encode!(mentioned_again)

    assert {:ok, :accepted} =
             SalixIM.ProviderHTTP.handle_slack_event(
               connect,
               mentioned_again,
               sign_slack_body(mentioned_again_raw, secret),
               mentioned_again_raw
             )

    settle_receive({:agent_delivery, ^agent_id, third_payload, _third_opts})
    assert third_payload.content =~ "explicit follow up after joining"
    refute Map.has_key?(third_payload, :pre_deliveries)
    refute third_payload.content =~ "This is the Router's first entry"

    assert length(MockSlack.requests("conversations.replies")) == 1
  end

  test "Slack Router participation is isolated by connect, installation, channel, and thread identity",
       %{
         tenant: tenant,
         group_id: group_id
       } do
    secret = "slack-secret"

    participating_connect =
      seed_slack_inbound_connect(group_id, tenant, "sl-cache-identity-a", secret)

    other_connect =
      seed_slack_inbound_connect(group_id, tenant, "sl-cache-identity-b", secret)

    assert :ok =
             SalixStore.SlackRouterThreadParticipations.record(
               group_id,
               participating_connect["connect_id"],
               participating_connect["workspace_id"],
               participating_connect["bot_user_id"],
               "C-cache-identity",
               "106.0"
             )

    assert SalixStore.SlackRouterThreadParticipations.participating?(
             group_id,
             participating_connect["connect_id"],
             participating_connect["workspace_id"],
             participating_connect["bot_user_id"],
             "C-cache-identity",
             "106.0"
           )

    refute SalixStore.SlackRouterThreadParticipations.participating?(
             group_id,
             other_connect["connect_id"],
             other_connect["workspace_id"],
             other_connect["bot_user_id"],
             "C-cache-identity",
             "106.0"
           )

    refute SalixStore.SlackRouterThreadParticipations.participating?(
             group_id,
             participating_connect["connect_id"],
             "T-other",
             participating_connect["bot_user_id"],
             "C-cache-identity",
             "106.0"
           )

    refute SalixStore.SlackRouterThreadParticipations.participating?(
             group_id,
             participating_connect["connect_id"],
             participating_connect["workspace_id"],
             "Ubot-other",
             "C-cache-identity",
             "106.0"
           )

    refute SalixStore.SlackRouterThreadParticipations.participating?(
             group_id,
             participating_connect["connect_id"],
             participating_connect["workspace_id"],
             participating_connect["bot_user_id"],
             "C-other-channel",
             "106.0"
           )

    refute SalixStore.SlackRouterThreadParticipations.participating?(
             group_id,
             participating_connect["connect_id"],
             participating_connect["workspace_id"],
             participating_connect["bot_user_id"],
             "C-cache-identity",
             "106.9"
           )

    MockSlack.respond("conversations.replies", %{
      "ok" => true,
      "messages" => [%{"type" => "message", "user" => "U1", "ts" => "106.0"}]
    })

    envelope =
      slack_envelope("Ev-cache-identity-isolated", %{
        "type" => "message",
        "user" => "U2",
        "text" => "do not borrow another connect's participation",
        "channel" => "C-cache-identity",
        "channel_type" => "channel",
        "ts" => "106.1",
        "thread_ts" => "106.0"
      })

    raw = Jason.encode!(envelope)

    assert {:error, :ignored} =
             SalixIM.ProviderHTTP.handle_slack_event(
               other_connect,
               envelope,
               sign_slack_body(raw, secret),
               raw
             )

    assert length(MockSlack.requests("conversations.replies")) == 1
  end

  test "Slack Router participation does not survive OAuth reauthorization to another installation",
       %{
         tenant: tenant,
         group_id: group_id
       } do
    secret = "slack-secret"
    original = seed_slack_inbound_connect(group_id, tenant, "sl-cache-reauthorize", secret)

    assert :ok =
             SalixStore.SlackRouterThreadParticipations.record(
               group_id,
               original["connect_id"],
               original["workspace_id"],
               original["bot_user_id"],
               "C-cache-reauthorize",
               "106.5"
             )

    assert {:ok, reset} =
             SalixIM.ProviderConnects.update_slack_im_connect(
               tenant,
               group_id,
               original["connect_id"],
               %{"reset_oauth" => true}
             )

    assert {:ok, _public_connect} =
             SalixIM.ProviderConnects.complete_slack_im_connect_oauth(reset, %{
               "bot_token" => "xoxb-reauthorized",
               "bot_id" => "B-reauthorized",
               "bot_user_id" => "Ubot-reauthorized",
               "bot_username" => "reauthorized-bot",
               "workspace_id" => "T-reauthorized",
               "workspace_name" => "Reauthorized workspace",
               "enterprise_id" => nil,
               "owner_user_id" => "Uowner"
             })

    assert {:ok, reauthorized} =
             SalixIM.ProviderConnects.get_active_connect_by_id(
               group_id,
               original["connect_id"],
               "slack"
             )

    MockSlack.respond("conversations.replies", %{
      "ok" => true,
      "messages" => [
        %{"type" => "message", "user" => "U1", "ts" => "106.5"},
        %{"type" => "message", "user" => original["bot_user_id"], "ts" => "106.6"}
      ]
    })

    envelope =
      slack_envelope("Ev-cache-reauthorized", %{
        "type" => "message",
        "user" => "U2",
        "text" => "do not reuse the previous installation's participation",
        "channel" => "C-cache-reauthorize",
        "channel_type" => "channel",
        "ts" => "106.7",
        "thread_ts" => "106.5"
      })
      |> Map.put("team_id", reauthorized["workspace_id"])

    raw = Jason.encode!(envelope)

    assert {:error, :ignored} =
             SalixIM.ProviderHTTP.handle_slack_event(
               reauthorized,
               envelope,
               sign_slack_body(raw, secret),
               raw
             )

    assert [%{auth: "Bearer xoxb-reauthorized"}] =
             MockSlack.requests("conversations.replies")

    assert SalixStore.SlackRouterThreadParticipations.participating?(
             group_id,
             original["connect_id"],
             original["workspace_id"],
             original["bot_user_id"],
             "C-cache-reauthorize",
             "106.5"
           )

    refute SalixStore.SlackRouterThreadParticipations.participating?(
             group_id,
             reauthorized["connect_id"],
             reauthorized["workspace_id"],
             reauthorized["bot_user_id"],
             "C-cache-reauthorize",
             "106.5"
           )
  end

  test "Slack thread replies settle through explicit exact-target egress only", %{
    tenant: tenant,
    group_id: group_id,
    agent_id: agent_id
  } do
    # External Slack input owns an exact provider-reply obligation. The model
    # must resolve it through an explicit same-thread call; ordinary assistant
    # final text remains session-only and must not create an extra Slack post.
    secret = "slack-secret"
    connect = seed_slack_inbound_connect(group_id, tenant, "sl-thread-silent", secret)

    MockSlack.respond("chat.postMessage", %{
      "ok" => true,
      "channel" => "C1",
      "ts" => "300.4"
    })

    SalixAgent.LLM.Mock.script(
      Enum.flat_map(1..2, fn index ->
        [
          {:assistant, "",
           [
             %{
               id: "slack-thread-explicit-reply-#{index}",
               name: "call",
               args: %{
                 "tool" => "im_api.slack.reply_message",
                 "params" => %{
                   "connect_id" => connect["connect_id"],
                   "channel" => "C1",
                   "thread_ts" => "300.0",
                   "text" => "explicit thread reply #{index}"
                 }
               }
             }
           ]},
          {:final, "session-only final #{index}"}
        ]
      end)
    )

    MockSlack.respond("conversations.replies", %{
      "ok" => true,
      "messages" => [
        %{"type" => "message", "user" => "U1", "text" => "root", "ts" => "300.0"},
        %{"type" => "message", "user" => "Ubot", "text" => "bot reply", "ts" => "300.1"}
      ]
    })

    for {{event_id, user_id, text, ts}, index} <-
          Enum.with_index(
            [
              {"Ev-thread-silent-a", "U1", "first thread reply", "300.2"},
              {"Ev-thread-silent-b", "U2", "second thread reply", "300.3"}
            ],
            1
          ) do
      envelope =
        slack_envelope(event_id, %{
          "type" => "message",
          "user" => user_id,
          "text" => text,
          "channel" => "C1",
          "channel_type" => "channel",
          "ts" => ts,
          "thread_ts" => "300.0"
        })

      raw = Jason.encode!(envelope)

      assert {:ok, :accepted} =
               SalixIM.ProviderHTTP.handle_slack_event(
                 connect,
                 envelope,
                 sign_slack_body(raw, secret),
                 raw
               )

      assert_router_session_delivery(
        tenant,
        group_id,
        agent_id,
        "im_provider:slack:#{connect["connect_id"]}:#{event_id}",
        text
      )

      assert eventually(fn -> length(MockSlack.requests("chat.postMessage")) == index end, 1200)
    end

    {:ok, session_id} = SalixIM.ProviderConnects.agent_group_router_session_id(agent_id, group_id)

    assert eventually(fn ->
             case SalixAgent.TestSupport.SessionData.read(agent_id, session_id) do
               {:ok, session} -> Enum.count(session.messages, &(&1.role == "user")) == 2
               _ -> false
             end
           end)

    {:ok, session} = SalixAgent.TestSupport.SessionData.read(agent_id, session_id)
    assert Enum.count(session.messages, &(&1.role == "user")) == 2
    assert length(MockSlack.requests("conversations.replies")) == 1

    rendered_requests =
      Enum.map(MockSlack.requests("chat.postMessage"), fn request ->
        Map.update!(request.params, "blocks", &Jason.decode!/1)
      end)

    assert rendered_requests == [
             %{
               "blocks" => [
                 %{"type" => "markdown", "text" => "explicit thread reply 1"}
               ],
               "channel" => "C1",
               "thread_ts" => "300.0",
               "text" => "explicit thread reply 1"
             },
             %{
               "blocks" => [
                 %{"type" => "markdown", "text" => "explicit thread reply 2"}
               ],
               "channel" => "C1",
               "thread_ts" => "300.0",
               "text" => "explicit thread reply 2"
             }
           ]

    refute inspect(MockSlack.requests("chat.postMessage")) =~ "session-only final"
  end

  test "Feishu meeting fast path requires a real bot mention and bypasses the Router", %{
    tenant: tenant,
    group_id: group_id
  } do
    parent = SystemsRuntime.Proc.self()
    previous = SystemsRuntime.get_env(:salix_im, :meeting_provider_handler)

    SystemsRuntime.put_env(:salix_im, :meeting_provider_handler, fn connect, envelope ->
      SystemsRuntime.Proc.send(
        parent,
        {:meeting_provider_called, connect["connect_id"], envelope}
      )

      {:ok, :handled}
    end)

    on_exit(fn -> restore(:salix_im, :meeting_provider_handler, previous) end)

    connect =
      seed_connect(group_id, "fs-meeting-fast-path", "feishu", %{
        "tenant_id" => tenant,
        "app_id" => "cli_meeting",
        "bot_open_id" => "ou_bot",
        "verification_token" => "verify-token",
        "status" => "connected"
      })

    real_mention = %{
      "schema" => "2.0",
      "header" => %{
        "app_id" => "cli_meeting",
        "event_id" => "evt_meeting_real",
        "token" => "verify-token"
      },
      "event" => %{
        "sender" => %{"sender_id" => %{"open_id" => "ou_user"}},
        "message" => %{
          "message_id" => "om_meeting_real",
          "chat_id" => "oc_meeting",
          "chat_type" => "group",
          "thread_id" => "omt_meeting",
          "message_type" => "text",
          "mentions" => [
            %{"key" => "@_user_1", "id" => %{"open_id" => "ou_bot"}, "name" => "BFT"}
          ],
          "content" =>
            Jason.encode!(%{"text" => "@_user_1 入会 https://meet.google.com/abc-defg-hij"})
        }
      }
    }

    assert {:ok, %{ok: true, status: "handled"}} =
             SalixIM.ProviderHTTP.handle_feishu_event(
               connect,
               real_mention,
               [],
               Jason.encode!(real_mention)
             )

    settle_receive({:meeting_provider_called, "fs-meeting-fast-path", ^real_mention})

    textual_mention =
      put_in(real_mention, ["header", "event_id"], "evt_meeting_textual")
      |> put_in(["event", "message", "message_id"], "om_meeting_textual")
      |> put_in(["event", "message", "mentions"], [])
      |> put_in(
        ["event", "message", "content"],
        Jason.encode!(%{"text" => "@jinfei-bft-test 入会 https://meet.google.com/abc-defg-hij"})
      )

    assert {:error, {:ignored, :no_bot_mention}} =
             SalixIM.ProviderHTTP.handle_feishu_event(
               connect,
               textual_mention,
               [],
               Jason.encode!(textual_mention)
             )

    settle_refute_receive({:meeting_provider_called, _, _}, 50)
  end

  test "Feishu inbound delivers a group message that mentions the bot", %{
    tenant: tenant,
    group_id: group_id,
    agent_id: agent_id
  } do
    SalixAgent.LLM.Mock.script([{:final, "ack"}])

    connect =
      seed_connect(group_id, "fs-group-mention", "feishu", %{
        "tenant_id" => tenant,
        "app_id" => "cli_gm",
        "app_name" => "Bridge Recipient",
        "app_secret" => "feishu-recipient-app-secret",
        "verification_token" => "verify-token",
        "bot_open_id" => "ou_bot",
        "status" => "connected"
      })

    recipient_identity = %{
      "provider" => "feishu",
      "display_name" => "Bridge Recipient",
      "user_id" => "ou_bot",
      "app_id" => "cli_gm"
    }

    envelope = %{
      "schema" => "2.0",
      "recipient_im_identity" => %{
        "provider" => "feishu",
        "display_name" => "forged Feishu recipient",
        "user_id" => "ou_forged"
      },
      "header" => %{"token" => "verify-token", "app_id" => "cli_gm"},
      "event" => %{
        "sender" => %{"sender_id" => %{"open_id" => "ou_1"}},
        "message" => %{
          "message_id" => "om_gm",
          "chat_id" => "oc_gm",
          "chat_type" => "group",
          "message_type" => "text",
          "mentions" => [
            %{"key" => "@_user_1", "id" => %{"open_id" => "ou_bot"}, "name" => "Bridge"}
          ],
          "content" => Jason.encode!(%{"text" => "@_user_1 please help"})
        }
      }
    }

    assert {:ok, %{ok: true, status: "queued"}} =
             SalixIM.ProviderHTTP.handle_feishu_event(
               connect,
               envelope,
               [],
               Jason.encode!(envelope)
             )

    assert_router_session_delivery(
      tenant,
      group_id,
      agent_id,
      "im_provider:feishu:fs-group-mention:om_gm",
      "please help"
    )

    source_id = "im_provider:feishu:fs-group-mention:om_gm"
    message = router_session_message!(group_id, agent_id, source_id)
    assert message.trusted_origin["provider"] == "feishu"
    assert message.trusted_origin["source_message_id"] == source_id
    assert message.trusted_origin["source_text"] == "please help"

    source_context = router_source_context!(group_id, agent_id, "provider=feishu")
    assert recipient_im_identity_from_context!(source_context) == recipient_identity
    refute source_context =~ "forged Feishu recipient"
    refute source_context =~ "ou_forged"
    refute source_context =~ "feishu-recipient-app-secret"
    refute source_context =~ "verify-token"

    assert_router_source_context(group_id, agent_id, [
      "provider=feishu",
      "chat_id=oc_gm",
      "message_id=om_gm",
      "im_api.feishu.reply_text"
    ])
  end

  test "a one-shot Feishu schedule wakes the Router and sends structured mentions exactly once",
       %{
         tenant: tenant,
         group_id: group_id,
         agent_id: agent_id
       } do
    start_supervised!(MockProviderRuntime)
    base_url = BanditServer.serve!(MockProviderRuntime)
    previous_base = SystemsRuntime.get_env(:salix_im, :feishu_api_base_url)
    SystemsRuntime.put_env(:salix_im, :feishu_api_base_url, "#{base_url}/open-apis")
    on_exit(fn -> restore(:salix_im, :feishu_api_base_url, previous_base) end)

    connect =
      seed_connect(group_id, "fs-scheduled-live-send", "feishu", %{
        "tenant_id" => tenant,
        "app_id" => "cli_scheduled_live_send",
        "app_name" => "Bridge",
        "bot_open_id" => "ou_bot",
        "status" => "connected"
      })

    {:ok, session_id} = SalixIM.ProviderConnects.agent_group_router_session_id(agent_id, group_id)
    {:ok, _pid} = SalixAgent.Fleet.ensure_started(agent_id, create: false)

    SalixAgent.LLM.Mock.script([
      {:assistant, "发送到飞书群",
       [
         %{
           id: "scheduled-live-send",
           name: "call",
           args: %{
             "tool" => "im_api.feishu.send_text",
             "params" => %{
               "connect_id" => connect["connect_id"],
               "receive_id" => "oc_schedule_team",
               "text" => "会议将在十分钟后开始，请准备材料",
               "mentions" => [%{"user_id" => "ou_alice", "name" => "Alice"}],
               "mention_all" => true
             }
           }
         }
       ]},
      {:final, "done"}
    ])

    prompt =
      ~s(Call im_api.feishu.send_text with connect_id="#{connect["connect_id"]}", receive_id="oc_schedule_team", text="会议将在十分钟后开始，请准备材料", mentions=[{"user_id":"ou_alice","name":"Alice"}], mention_all=true.)

    schedule =
      SalixAgent.Tools.Schedules.create_schedule(
        %{
          "run_at" => "2027-01-02T09:50:00+08:00",
          "prompt" => prompt
        },
        %{agent_id: agent_id, session_id: session_id, state: nil}
      )
      |> Jason.decode!()

    run_at = schedule["run_at"]
    schedule_id = schedule["id"]

    assert {:ok, %{fired: [^schedule_id], failed: []}} =
             SalixCluster.Schedules.run_once(now: run_at)

    assert eventually(fn -> length(MockProviderRuntime.requests(:feishu_message)) == 1 end)

    [message] = MockProviderRuntime.requests(:feishu_message)
    assert message.query["receive_id_type"] == "chat_id"
    assert message.params["receive_id"] == "oc_schedule_team"
    assert message.params["msg_type"] == "post"

    assert get_in(Jason.decode!(message.params["content"]), ["zh_cn", "content"]) == [
             [
               %{"tag" => "at", "user_id" => "ou_alice", "user_name" => "Alice"},
               %{"tag" => "at", "user_id" => "all", "user_name" => "所有人"}
             ],
             [%{"tag" => "md", "text" => "会议将在十分钟后开始，请准备材料"}]
           ]

    assert {:error, :not_found} = SalixCluster.Schedules.get(schedule_id)

    assert {:ok, %{fired: [], failed: []}} =
             SalixCluster.Schedules.run_once(now: run_at + 1)

    assert length(MockProviderRuntime.requests(:feishu_message)) == 1

    assert eventually(fn ->
             case SalixAgent.TestSupport.SessionData.read(agent_id, session_id) do
               {:ok, session} ->
                 session.messages
                 |> tool_terminal_content("scheduled-live-send")
                 |> then(&(is_binary(&1) and String.contains?(&1, "om_sent")))

               _ ->
                 false
             end
           end)
  end

  test "a schedule owned by a replaced Router cannot send through the Feishu connect", %{
    tenant: tenant,
    group_id: group_id,
    agent_id: old_router_id
  } do
    start_supervised!(MockProviderRuntime)
    base_url = BanditServer.serve!(MockProviderRuntime)
    previous_base = SystemsRuntime.get_env(:salix_im, :feishu_api_base_url)
    SystemsRuntime.put_env(:salix_im, :feishu_api_base_url, "#{base_url}/open-apis")
    on_exit(fn -> restore(:salix_im, :feishu_api_base_url, previous_base) end)

    connect =
      seed_connect(group_id, "fs-replaced-router-schedule", "feishu", %{
        "tenant_id" => tenant,
        "app_id" => "cli_replaced_router_schedule",
        "app_name" => "Bridge",
        "bot_open_id" => "ou_bot",
        "status" => "connected"
      })

    {:ok, old_session_id} =
      SalixIM.ProviderConnects.agent_group_router_session_id(old_router_id, group_id)

    {:ok, _pid} = SalixAgent.Fleet.ensure_started(old_router_id, create: false)

    SalixAgent.LLM.Mock.script([
      {:assistant, "尝试发送旧 Router 的定时消息",
       [
         %{
           id: "stale-router-send",
           name: "call",
           args: %{
             "tool" => "im_api.feishu.send_text",
             "params" => %{
               "connect_id" => connect["connect_id"],
               "receive_id" => "oc_schedule_team",
               "text" => "stale Router must not send"
             }
           }
         }
       ]},
      {:final, "done"}
    ])

    schedule =
      SalixAgent.Tools.Schedules.create_schedule(
        %{
          "run_at" => "2027-01-02T09:50:00+08:00",
          "prompt" => "Send the configured Feishu reminder now."
        },
        %{agent_id: old_router_id, session_id: old_session_id, state: nil}
      )
      |> Jason.decode!()

    {:ok, new_router} =
      create_control_agent(
        %{"name" => "Replacement Router", "group_id" => group_id, "role" => "router"},
        tenant
      )

    {:ok, _group} =
      SalixStore.CasRecord.update(Keys.ctl_group(group_id), fn group ->
        Map.put(group, "router_agent_id", new_router["agent_id"])
      end)

    assert {:ok, %{fired: [schedule_id], failed: []}} =
             SalixCluster.Schedules.run_once(now: schedule["run_at"])

    assert schedule_id == schedule["id"]

    assert eventually(fn ->
             case SalixAgent.TestSupport.SessionData.read(old_router_id, old_session_id) do
               {:ok, session} ->
                 Enum.any?(session.messages, fn message ->
                   message.role == "tool" and message.tool_call_id == "stale-router-send"
                 end)

               _ ->
                 false
             end
           end)

    assert MockProviderRuntime.requests(:feishu_message) == []
  end

  test "Feishu mention reads earlier facts from its explicit current thread and replies", %{
    tenant: tenant,
    group_id: group_id,
    agent_id: agent_id
  } do
    start_supervised!(MockProviderRuntime)
    base_url = BanditServer.serve!(MockProviderRuntime)
    previous_base = SystemsRuntime.get_env(:salix_im, :feishu_api_base_url)
    SystemsRuntime.put_env(:salix_im, :feishu_api_base_url, "#{base_url}/open-apis")
    on_exit(fn -> restore(:salix_im, :feishu_api_base_url, previous_base) end)

    connect =
      seed_connect(group_id, "fs-history-answer", "feishu", %{
        "tenant_id" => tenant,
        "app_id" => "cli_history_answer",
        "app_name" => "Bridge",
        "bot_open_id" => "ou_bot",
        "status" => "connected"
      })

    MockProviderRuntime.feishu_message_responder(fn _query ->
      %{
        "items" => [
          %{
            "message_id" => "om_office_facts",
            "chat_id" => "oc_history",
            "root_id" => "om_office_root",
            "thread_id" => "omt_office",
            "msg_type" => "text",
            "sender" => %{"id" => "ou_admin", "sender_name" => "Admin"},
            "body" => %{
              "content" =>
                Jason.encode!(%{
                  "text" => "WiFi 密码是 Comma-2026；公司地址是上海市徐汇区 100 号"
                })
            }
          }
        ],
        "has_more" => false,
        "page_token" => ""
      }
    end)

    SalixAgent.LLM.Mock.script([
      {:assistant, "先读取当前话题历史",
       [
         %{
           id: "thread-history",
           name: "call",
           args: %{
             "tool" => "im_api.feishu.get_thread_replies",
             "params" => %{
               "connect_id" => connect["connect_id"],
               "thread_id" => "omt_office"
             }
           }
         }
       ]},
      {:assistant, "把查到的事实回复到当前群话题",
       [
         %{
           id: "history-reply",
           name: "call",
           args: %{
             "tool" => "im_api.feishu.reply_text",
             "params" => %{
               "connect_id" => connect["connect_id"],
               "message_id" => "om_history_question",
               "chat_id" => "oc_history",
               "chat_type" => "group",
               "reply_in_thread" => true,
               "text" => "WiFi 密码是 Comma-2026；公司地址是上海市徐汇区 100 号"
             }
           }
         }
       ]},
      {:final, "done"}
    ])

    envelope = %{
      "schema" => "2.0",
      "header" => %{"token" => "verify-token", "app_id" => "cli_history_answer"},
      "event" => %{
        "sender" => %{"sender_id" => %{"open_id" => "ou_asker"}},
        "message" => %{
          "message_id" => "om_history_question",
          "chat_id" => "oc_history",
          "chat_type" => "group",
          "root_id" => "om_office_root",
          "thread_id" => "omt_office",
          "message_type" => "text",
          "mentions" => [
            %{"key" => "@_user_1", "id" => %{"open_id" => "ou_bot"}, "name" => "Bridge"}
          ],
          "content" => Jason.encode!(%{"text" => "@_user_1 wifi 密码和公司地址是什么？"})
        }
      }
    }

    assert {:ok, %{ok: true, status: "queued"}} =
             SalixIM.ProviderHTTP.handle_feishu_event(
               connect,
               envelope,
               [],
               Jason.encode!(envelope)
             )

    assert eventually(fn -> length(MockProviderRuntime.requests(:feishu_list_messages)) == 1 end)
    assert eventually(fn -> length(MockProviderRuntime.requests(:feishu_reply)) == 1 end)

    [thread_request] = MockProviderRuntime.requests(:feishu_list_messages)
    assert thread_request.query["container_id_type"] == "thread"
    assert thread_request.query["container_id"] == "omt_office"

    [reply] = MockProviderRuntime.requests(:feishu_reply)
    assert reply.message_id == "om_history_question"
    assert reply.params["reply_in_thread"] == true

    assert reply.params["msg_type"] == "post"

    assert SalixIM.Provider.Feishu.Message.text(reply.params) ==
             "WiFi 密码是 Comma-2026；公司地址是上海市徐汇区 100 号"

    {:ok, session_id} = SalixIM.ProviderConnects.agent_group_router_session_id(agent_id, group_id)

    assert eventually(fn ->
             case SalixAgent.TestSupport.SessionData.read(agent_id, session_id) do
               {:ok, session} ->
                 content = tool_terminal_content(session.messages, "thread-history")

                 is_binary(content) and String.contains?(content, "Comma-2026") and
                   String.contains?(content, "上海市徐汇区 100 号")

               _ ->
                 false
             end
           end)
  end

  test "Feishu creates and verifies a Google Meet event through the Slack-parity Composio path",
       %{
         tenant: tenant,
         group_id: group_id,
         agent_id: agent_id
       } do
    start_supervised!(MockProviderRuntime)
    start_supervised!(MockComposioClient)

    base_url = BanditServer.serve!(MockProviderRuntime)
    previous_base = SystemsRuntime.get_env(:salix_im, :feishu_api_base_url)
    previous_store = SystemsRuntime.get_env(:salix_agent, :composio_store_mod)
    previous_client = SystemsRuntime.get_env(:salix_agent, :composio_client_mod)
    previous_llm = SystemsRuntime.get_env(:salix_agent, :llm)
    SystemsRuntime.put_env(:salix_im, :feishu_api_base_url, "#{base_url}/open-apis")
    SystemsRuntime.put_env(:salix_agent, :composio_store_mod, MockComposioStore)
    SystemsRuntime.put_env(:salix_agent, :composio_client_mod, MockComposioClient)
    SystemsRuntime.put_env(:salix_agent, :llm, CalendarParityLLM)

    on_exit(fn ->
      CalendarParityLLM.clear()
      restore(:salix_im, :feishu_api_base_url, previous_base)
      restore(:salix_agent, :composio_store_mod, previous_store)
      restore(:salix_agent, :composio_client_mod, previous_client)
      restore(:salix_agent, :llm, previous_llm)
    end)

    connected_account_id = "ca_calendar_only"
    start_at = "2026-07-21T10:00:00+08:00"
    end_at = "2026-07-21T10:30:00+08:00"
    meet_url = "https://meet.google.com/abc-defg-hij"

    MockComposioClient.configure(
      [
        %{
          "id" => connected_account_id,
          "user_id" => group_id,
          "toolkit" => %{"slug" => "googlecalendar"},
          "status" => "ACTIVE"
        }
      ],
      %{
        "GOOGLECALENDAR_CREATE_EVENT" =>
          {:ok,
           %{
             "successful" => true,
             "data" => %{
               "id" => "event-1",
               "calendar_id" => "primary",
               "start" => %{"dateTime" => start_at, "timeZone" => "Asia/Singapore"},
               "end" => %{"dateTime" => end_at, "timeZone" => "Asia/Singapore"},
               "attendees" => [%{"email" => "alice@example.com"}],
               "hangoutLink" => meet_url
             }
           }},
        "GOOGLECALENDAR_GET_EVENT" =>
          {:ok,
           %{
             "successful" => true,
             "data" => %{
               "id" => "event-1",
               "calendar_id" => "primary",
               "summary" => "项目同步会",
               "start" => %{"dateTime" => start_at, "timeZone" => "Asia/Singapore"},
               "end" => %{"dateTime" => end_at, "timeZone" => "Asia/Singapore"},
               "attendees" => [%{"email" => "alice@example.com"}],
               "hangoutLink" => meet_url
             }
           }}
      }
    )

    connect =
      seed_connect(group_id, "fs-calendar-create", "feishu", %{
        "tenant_id" => tenant,
        "app_id" => "cli_calendar_create",
        "app_name" => "Bridge",
        "bot_open_id" => "ou_bot",
        "status" => "connected"
      })

    create_arguments = %{
      "calendar_id" => "primary",
      "summary" => "项目同步会",
      "start" => %{"dateTime" => start_at, "timeZone" => "Asia/Singapore"},
      "end" => %{"dateTime" => end_at, "timeZone" => "Asia/Singapore"},
      "attendees" => [%{"email" => "alice@example.com"}],
      "conference_data" => %{"create_request" => %{"request_id" => "feishu-event-1"}},
      "send_updates" => "all"
    }

    CalendarParityLLM.configure(%{
      connect_id: connect["connect_id"],
      message_id: "om_calendar_create",
      chat_id: "oc_calendar",
      connected_account_id: connected_account_id,
      calendar_id: "primary",
      summary: "项目同步会",
      start_at: start_at,
      end_at: end_at,
      timezone: "Asia/Singapore",
      attendee_email: "alice@example.com",
      meet_url: meet_url,
      create_arguments: create_arguments
    })

    envelope = %{
      "schema" => "2.0",
      "header" => %{"token" => "verify-token", "app_id" => "cli_calendar_create"},
      "event" => %{
        "sender" => %{"sender_id" => %{"open_id" => "ou_asker"}},
        "message" => %{
          "message_id" => "om_calendar_create",
          "chat_id" => "oc_calendar",
          "chat_type" => "group",
          "message_type" => "text",
          "mentions" => [
            %{"key" => "@_user_1", "id" => %{"open_id" => "ou_bot"}, "name" => "Bridge"},
            %{"key" => "@_user_2", "id" => %{"open_id" => "ou_alice"}, "name" => "Alice"}
          ],
          "content" =>
            Jason.encode!(%{
              "text" =>
                "@_user_1 创建项目同步会，邀请 @_user_2，时间是 2026-07-21 10:00-10:30 Asia/Singapore，并创建 Google Meet"
            })
        }
      }
    }

    assert {:ok, %{ok: true, status: "queued"}} =
             SalixIM.ProviderHTTP.handle_feishu_event(
               connect,
               envelope,
               [],
               Jason.encode!(envelope)
             )

    assert eventually(fn -> length(MockProviderRuntime.requests(:feishu_get_user)) == 1 end)
    # Allow the seven tool calls to settle before checking the verified reply.
    assert eventually(fn -> length(MockProviderRuntime.requests(:feishu_reply)) == 1 end, 1200)

    execute_requests =
      MockComposioClient.requests()
      |> Enum.filter(&match?({:execute_tool, _, _, _, _, _}, &1))

    assert [
             {:execute_tool, _, "GOOGLECALENDAR_CREATE_EVENT", ^group_id, ^create_arguments,
              [connected_account_id: ^connected_account_id]},
             {:execute_tool, _, "GOOGLECALENDAR_GET_EVENT", ^group_id,
              %{"calendar_id" => "primary", "event_id" => "event-1"},
              [connected_account_id: ^connected_account_id]}
           ] = execute_requests

    [reply] = MockProviderRuntime.requests(:feishu_reply)
    assert reply.message_id == "om_calendar_create"
    assert reply.params["reply_in_thread"] == true
    reply_text = SalixIM.Provider.Feishu.Message.text(reply.params)
    assert reply_text =~ "已验证创建"
    assert reply_text =~ meet_url
    refute reply_text =~ "到点"
    refute reply_text =~ "通知"

    {:ok, session_id} = SalixIM.ProviderConnects.agent_group_router_session_id(agent_id, group_id)
    assert {:ok, session} = SalixAgent.TestSupport.SessionData.read(agent_id, session_id)

    refute Enum.any?(session.messages, fn message ->
             tool_calls = Map.get(message, :tool_calls) || Map.get(message, "tool_calls") || []

             Enum.any?(tool_calls, fn call ->
               (call["name"] || call[:name]) == "schedule.create"
             end)
           end)
  end

  test "Feishu inbound preserves WebP MIME while streaming the triggering image into Router VFS",
       %{
         tenant: tenant,
         group_id: group_id,
         agent_id: agent_id
       } do
    SalixAgent.LLM.Mock.script([{:final, "ack"}])
    start_supervised!(MockProviderRuntime)
    base_url = BanditServer.serve!(MockProviderRuntime)
    previous_base = SystemsRuntime.get_env(:salix_im, :feishu_api_base_url)
    SystemsRuntime.put_env(:salix_im, :feishu_api_base_url, "#{base_url}/open-apis")
    on_exit(fn -> restore(:salix_im, :feishu_api_base_url, previous_base) end)
    MockProviderRuntime.feishu_resource("image/webp", @webp)

    connect =
      seed_connect(group_id, "fs-inbound-image", "feishu", %{
        "tenant_id" => tenant,
        "app_id" => "cli_image",
        "app_name" => "Bridge",
        "bot_open_id" => "ou_bot",
        "status" => "connected"
      })

    envelope = %{
      "schema" => "2.0",
      "header" => %{"token" => "verify-token", "app_id" => "cli_image"},
      "event" => %{
        "sender" => %{"sender_id" => %{"open_id" => "ou_1"}},
        "message" => %{
          "message_id" => "om_image",
          "chat_id" => "oc_image",
          "chat_type" => "group",
          "message_type" => "image",
          "mentions" => [
            %{"key" => "@_user_1", "id" => %{"open_id" => "ou_bot"}, "name" => "Bridge"}
          ],
          "content" => Jason.encode!(%{"image_key" => "img-trigger"})
        }
      }
    }

    assert {:ok, %{ok: true, status: "queued"}} =
             SalixIM.ProviderHTTP.handle_feishu_event(
               connect,
               envelope,
               [],
               Jason.encode!(envelope)
             )

    staged_path =
      SalixIM.FeishuFiles.inbound_path("oc_image", "om_image", %{
        "file_key" => "img-trigger",
        "file_name" => "image.webp"
      })

    assert_router_session_delivery(
      tenant,
      group_id,
      agent_id,
      "im_provider:feishu:fs-inbound-image:om_image",
      staged_path
    )

    assert {:ok, %{data: @webp}} =
             SalixIM.Ports.AgentWorkspace.read_upload(agent_id, staged_path)

    [resource_request] = MockProviderRuntime.requests(:feishu_message_resource)
    assert resource_request.message_id == "om_image"
    assert resource_request.file_key == "img-trigger"
    assert resource_request.query["type"] == "image"
  end

  test "Feishu group thread continues without another mention only after bot participation", %{
    tenant: tenant,
    group_id: group_id,
    agent_id: agent_id
  } do
    SalixAgent.LLM.Mock.script([{:final, "ack"}])

    connect =
      seed_connect(group_id, "fs-thread-followup", "feishu", %{
        "tenant_id" => tenant,
        "app_id" => "cli_thread",
        "app_name" => "Bridge",
        "bot_open_id" => "ou_bot",
        "status" => "connected"
      })

    assert :ok =
             SalixIM.ProviderConnects.record_feishu_thread_participation(
               connect,
               "oc_thread",
               "omt_joined"
             )

    envelope = %{
      "schema" => "2.0",
      "header" => %{"token" => "verify-token", "app_id" => "cli_thread"},
      "event" => %{
        "sender" => %{"sender_id" => %{"open_id" => "ou_1"}},
        "message" => %{
          "message_id" => "om_thread_followup",
          "chat_id" => "oc_thread",
          "chat_type" => "group",
          "thread_id" => "omt_joined",
          "message_type" => "text",
          "content" => Jason.encode!(%{"text" => "continue without mention"})
        }
      }
    }

    assert {:ok, %{ok: true, status: "queued"}} =
             SalixIM.ProviderHTTP.handle_feishu_event(
               connect,
               envelope,
               [],
               Jason.encode!(envelope)
             )

    assert_router_session_delivery(
      tenant,
      group_id,
      agent_id,
      "im_provider:feishu:fs-thread-followup:om_thread_followup",
      "continue without mention"
    )
  end

  test "Feishu inbound ignores a group message that does not mention the bot", %{
    tenant: tenant,
    group_id: group_id
  } do
    connect =
      seed_connect(group_id, "fs-group-plain", "feishu", %{
        "tenant_id" => tenant,
        "app_id" => "cli_gp",
        "app_name" => "Bridge",
        "bot_open_id" => "ou_bot",
        "status" => "connected"
      })

    envelope = %{
      "schema" => "2.0",
      "header" => %{"token" => "verify-token", "app_id" => "cli_gp"},
      "event" => %{
        "sender" => %{"sender_id" => %{"open_id" => "ou_1"}},
        "message" => %{
          "message_id" => "om_gp",
          "chat_id" => "oc_gp",
          "chat_type" => "group",
          "message_type" => "text",
          "mentions" => [
            %{"key" => "@_user_1", "id" => %{"open_id" => "ou_other"}, "name" => "Someone"}
          ],
          "content" => Jason.encode!(%{"text" => "@_user_1 ordinary group chatter"})
        }
      }
    }

    assert {:error, {:ignored, :bot_mention_mismatch}} =
             SalixIM.ProviderHTTP.handle_feishu_event(
               connect,
               envelope,
               [],
               Jason.encode!(envelope)
             )

    assert fake_records_with_prefix("ctl/im_feishu_event_receipts/fs-group-plain/") == %{}
  end

  test "Feishu inbound ignores signature when encrypt key is not configured", %{
    tenant: tenant,
    group_id: group_id,
    agent_id: agent_id
  } do
    SalixAgent.LLM.Mock.script([{:final, "ack"}])

    verification_token = "verify-token"

    FakeTenantAppStore.put(tenant, %{
      "app_secret" => "fs-secret",
      "verification_token" => verification_token
    })

    connect =
      seed_connect(group_id, "fs-signed-inbound", "feishu", %{
        "tenant_id" => tenant,
        "app_id" => "cli_signed",
        "status" => "connected"
      })

    envelope = %{
      "schema" => "2.0",
      "header" => %{"token" => verification_token, "app_id" => "cli_signed"},
      "event" => %{
        "sender" => %{"sender_id" => %{"open_id" => "ou_signed"}},
        "message" => %{
          "message_id" => "om_signed",
          "chat_id" => "oc_signed",
          "chat_type" => "p2p",
          "message_type" => "text",
          "content" => Jason.encode!(%{"text" => "signed direct message"})
        }
      }
    }

    raw = Jason.encode!(envelope)

    assert {:ok, %{ok: true, status: "queued"}} =
             SalixIM.ProviderHTTP.handle_feishu_event(
               connect,
               envelope,
               sign_feishu_body(raw, "wrong-signing-secret"),
               raw
             )

    assert_router_session_delivery(
      tenant,
      group_id,
      agent_id,
      "im_provider:feishu:fs-signed-inbound:om_signed",
      "signed direct message"
    )

    bad_token_envelope = put_in(envelope, ["header", "token"], "wrong-token")

    assert {:error, :invalid_token} =
             SalixIM.ProviderHTTP.handle_feishu_event(
               connect,
               bad_token_envelope,
               [],
               Jason.encode!(bad_token_envelope)
             )
  end

  test "Feishu inbound validates signature with encrypt key when configured", %{tenant: tenant} do
    verification_token = "verify-token"
    encrypt_key = "encrypt-secret"

    FakeTenantAppStore.put(tenant, %{
      "app_secret" => "fs-secret",
      "verification_token" => verification_token,
      "encrypt_key" => encrypt_key
    })

    connect = %{
      "connect_id" => "fs-signed-encrypted",
      "tenant_id" => tenant,
      "provider" => "feishu",
      "status" => "connected"
    }

    envelope = %{
      "schema" => "2.0",
      "header" => %{
        "token" => verification_token,
        "app_id" => "cli_signed",
        "event_type" => "url_verification"
      },
      "event" => %{"challenge" => "url-check"}
    }

    raw = Jason.encode!(envelope)

    assert {:ok, _response} =
             SalixIM.ProviderHTTP.handle_feishu_event(
               connect,
               envelope,
               sign_feishu_body(raw, encrypt_key),
               raw
             )

    assert {:error, :invalid_signature} =
             SalixIM.ProviderHTTP.handle_feishu_event(
               connect,
               envelope,
               sign_feishu_body(raw, "wrong-signing-secret"),
               raw
             )
  end

  test "provider receipts are rolled back when router delivery fails", %{tenant: tenant} do
    group_id = SalixStore.Ids.new_group_id(tenant)
    SalixAgent.TestSupport.create_control_group!(group_id, %{"name" => "No Router"})

    secret = "slack-retry-secret"

    {:ok, router} =
      create_control_agent(
        %{"name" => "Router", "group_id" => group_id, "role" => "router"},
        tenant
      )

    slack =
      seed_connect(group_id, "sl-retry", "slack", %{
        "tenant_id" => tenant,
        "app_id" => "A-retry",
        "signing_secret" => secret,
        "workspace_id" => "T-retry",
        "bot_token" => "xoxb-test",
        "bot_user_id" => "Ubot",
        "oauth_completed_at" => 1,
        "inbound_agent_id" => router["agent_id"]
      })

    slack_envelope = %{
      "type" => "event_callback",
      "api_app_id" => "A-retry",
      "team_id" => "T-retry",
      "event_id" => "Ev-retry",
      "event" => %{
        "type" => "app_mention",
        "user" => "U1",
        "text" => "<@Ubot> retry slack",
        "channel" => "C1",
        "ts" => "123.456"
      }
    }

    slack_raw = Jason.encode!(slack_envelope)

    assert {:error, :router_not_configured} =
             SalixIM.ProviderHTTP.handle_slack_event(
               slack,
               slack_envelope,
               sign_slack_body(slack_raw, secret),
               slack_raw
             )

    assert fake_records_with_prefix("ctl/im_slack_event_receipts/sl-retry/") == %{}

    telegram =
      seed_connect(group_id, "tg-retry", "telegram", %{
        "tenant_id" => tenant,
        "status" => "connected",
        "bot_token" => "123:abc",
        "bot_user_id" => "900",
        "bot_username" => "bridge_bot"
      })

    assert {:error, :router_not_configured} =
             SalixIM.ProviderHTTP.handle_telegram_update(telegram, %{
               "update_id" => 901,
               "message" => %{
                 "message_id" => 1,
                 "text" => "retry telegram",
                 "chat" => %{"id" => 1, "type" => "private"},
                 "from" => %{"id" => 2}
               }
             })

    assert fake_records_with_prefix("ctl/im_telegram_event_receipts/tg-retry/") == %{}

    wechat =
      seed_connect(group_id, "wx-retry", "wechat", %{
        "tenant_id" => tenant,
        "status" => "connected",
        "wechat_id" => "wx-retry",
        "token" => "wx-token",
        "base_url" => "https://clawbot.example"
      })

    assert {:error, :router_not_configured} =
             SalixIM.ProviderHTTP.handle_wechat_update(wechat, %{
               "client_id" => "wx-retry-message",
               "text" => "retry wechat",
               "context_token" => "ctx-retry"
             })

    assert fake_records_with_prefix("ctl/im_wechat_event_receipts/wx-retry/") == %{}

    feishu =
      seed_connect(group_id, "fs-retry", "feishu", %{
        "tenant_id" => tenant,
        "app_id" => "cli_retry",
        "app_secret" => "secret",
        "verification_token" => "verify-token",
        "status" => "connected"
      })

    feishu_envelope = %{
      "schema" => "2.0",
      "header" => %{"token" => "verify-token", "app_id" => "cli_retry"},
      "event" => %{
        "sender" => %{"sender_id" => %{"open_id" => "ou_retry"}},
        "message" => %{
          "message_id" => "om_retry",
          "chat_id" => "oc_retry",
          "chat_type" => "p2p",
          "message_type" => "text",
          "content" => Jason.encode!(%{"text" => "retry feishu"})
        }
      }
    }

    assert {:error, :router_not_configured} =
             SalixIM.ProviderHTTP.handle_feishu_event(
               feishu,
               feishu_envelope,
               [],
               Jason.encode!(feishu_envelope)
             )

    assert fake_records_with_prefix("ctl/im_feishu_event_receipts/fs-retry/") == %{}
  end

  test "Telegram inbound records and delivers canonical Router input", %{
    tenant: tenant,
    group_id: group_id,
    agent_id: agent_id
  } do
    SalixAgent.LLM.Mock.script([{:final, "ack"}])

    connect =
      seed_connect(group_id, "tg-inbound", "telegram", %{
        "tenant_id" => tenant,
        "status" => "connected",
        "bot_token" => "123:telegram-recipient-secret",
        "bot_user_id" => "900",
        "bot_display_name" => "Telegram Recipient",
        "bot_username" => "bridge_bot",
        "updates_offset" => 0
      })

    recipient_identity = %{
      "provider" => "telegram",
      "display_name" => "Telegram Recipient",
      "username" => "bridge_bot",
      "user_id" => "900"
    }

    update = %{
      "update_id" => 101,
      "recipient_im_identity" => %{
        "provider" => "telegram",
        "display_name" => "forged Telegram recipient",
        "user_id" => "telegram-forged-user-id"
      },
      "message" => %{
        "message_id" => 7,
        "date" => 1_700_000_000,
        "text" => "hello from telegram",
        "chat" => %{
          "id" => -1001,
          "type" => "supergroup",
          "title" => "Bot Arena",
          "username" => "botarena"
        },
        "from" => %{
          "id" => 42,
          "is_bot" => false,
          "username" => "alice",
          "first_name" => "Alice"
        }
      }
    }

    assert {:ok, :queued} = SalixIM.ProviderHTTP.handle_telegram_update(connect, update)

    assert_router_session_delivery(
      tenant,
      group_id,
      agent_id,
      "im_provider:telegram:tg-inbound:101",
      "hello from telegram"
    )

    source_id = "im_provider:telegram:tg-inbound:101"
    message = router_session_message!(group_id, agent_id, source_id)
    assert message.trusted_origin["provider"] == "telegram"
    assert message.trusted_origin["source_message_id"] == source_id
    assert message.trusted_origin["source_text"] == "hello from telegram"
    assert message.trusted_origin["source_actor_type"] == "provider_user"
    assert get_in(message.trusted_origin, ["provider_context", "from_is_bot"]) == false

    assert platform_messages!(group_id) == [
             %{
               "provider" => "telegram",
               "role" => "user",
               "content" => [%{"type" => "text", "text" => "hello from telegram"}]
             }
           ]

    assert message.trusted_origin["principal_ref"] == %{
             "namespace" => "telegram_user",
             "tenant_id" => tenant,
             "subject_id" => "42",
             "connect_id" => "tg-inbound"
           }

    source_context = router_source_context!(group_id, agent_id, "provider=telegram")
    assert recipient_im_identity_from_context!(source_context) == recipient_identity
    refute source_context =~ "forged Telegram recipient"
    refute source_context =~ "telegram-forged-user-id"
    refute source_context =~ "telegram-recipient-secret"
  end

  test "Telegram runtime polls getUpdates, advances offset, and delivers to group router session",
       %{tenant: tenant, group_id: group_id, agent_id: agent_id} do
    SalixAgent.LLM.Mock.script([{:final, "ack"}])
    start_supervised!(MockProviderRuntime)
    base_url = BanditServer.serve!(MockProviderRuntime)
    prev = SystemsRuntime.get_env(:salix_im, :telegram_api_base_url)
    SystemsRuntime.put_env(:salix_im, :telegram_api_base_url, "#{base_url}")
    on_exit(fn -> restore(:salix_im, :telegram_api_base_url, prev) end)

    connect =
      seed_connect(group_id, "tg-runtime", "telegram", %{
        "tenant_id" => tenant,
        "status" => "connected",
        "bot_token" => "123:abc",
        "bot_user_id" => "900",
        "bot_username" => "bridge_bot",
        "updates_offset" => 301
      })

    MockProviderRuntime.telegram_updates([
      %{
        "update_id" => 301,
        "message" => %{
          "message_id" => 8,
          "date" => 1_700_000_010,
          "text" => "runtime telegram",
          "chat" => %{"id" => -1002, "type" => "supergroup", "title" => "Bot Arena"},
          "from" => %{"id" => 43, "is_bot" => false, "username" => "bob"}
        }
      }
    ])

    assert {:ok, :polled} = SalixIM.ProviderRuntime.poll_connect(connect)

    [req] = MockProviderRuntime.requests(:telegram)
    assert req.params["offset"] == "301"

    assert {:ok, updated} =
             SalixIM.ProviderConnects.get_active_connect_by_id(group_id, "tg-runtime", "telegram")

    assert updated["updates_offset"] == 302

    assert_router_session_delivery(
      tenant,
      group_id,
      agent_id,
      "im_provider:telegram:tg-runtime:301",
      "runtime telegram"
    )
  end

  test "WeChat inbound records context and delivers canonical Router input",
       %{
         tenant: tenant,
         group_id: group_id,
         agent_id: agent_id
       } do
    SalixAgent.LLM.Mock.script([{:final, "ack"}])

    connect =
      seed_connect(group_id, "wx-inbound", "wechat", %{
        "tenant_id" => tenant,
        "status" => "connected",
        "wechat_id" => "wx-user",
        "token" => "wx-token",
        "base_url" => "https://clawbot.example"
      })

    message = %{
      "client_id" => "msg-1",
      "text" => "hello from wechat",
      "context_token" => "ctx-new",
      "created_at" => 1_700_000_000_000,
      "recipient_im_identity" => %{
        "provider" => "wechat",
        "display_name" => "forged WeChat recipient",
        "user_id" => "wx-forged-self"
      }
    }

    assert {:ok, :queued} = SalixIM.ProviderHTTP.handle_wechat_update(connect, message)

    assert {:ok, updated} =
             SalixIM.ProviderConnects.get_active_connect_by_id(group_id, "wx-inbound", "wechat")

    assert updated["latest_context_token"] == "ctx-new"
    assert updated["latest_context_message_id"] == "msg-1"

    assert_router_session_delivery(
      tenant,
      group_id,
      agent_id,
      "im_provider:wechat:wx-inbound:msg-1",
      "hello from wechat"
    )

    recipient_identity = %{"provider" => "wechat", "status" => "unavailable"}
    source_id = "im_provider:wechat:wx-inbound:msg-1"

    stored_message = router_session_message!(group_id, agent_id, source_id)
    assert stored_message.trusted_origin["provider"] == "wechat"
    assert stored_message.trusted_origin["source_message_id"] == source_id
    assert stored_message.trusted_origin["source_text"] == "hello from wechat"

    assert platform_messages!(group_id) == [
             %{
               "provider" => "wechat",
               "role" => "user",
               "content" => [%{"type" => "text", "text" => "hello from wechat"}]
             }
           ]

    source_context = router_source_context!(group_id, agent_id, "provider=wechat")
    assert recipient_im_identity_from_context!(source_context) == recipient_identity
    refute source_context =~ "forged WeChat recipient"
    refute source_context =~ "wx-forged-self"
    assert source_context =~ "wechat_id=wx-user"
    refute Jason.encode!(recipient_identity) =~ "wx-user"
    refute source_context =~ "wx-token"
    refute source_context =~ "clawbot.example"
  end

  test "WeChat runtime does not advance cursor when message handling fails", %{tenant: tenant} do
    start_supervised!(MockProviderRuntime)
    base_url = BanditServer.serve!(MockProviderRuntime)

    group_id = SalixStore.Ids.new_group_id(tenant)
    SalixAgent.TestSupport.create_control_group!(group_id, %{"name" => "No Router"})

    connect =
      seed_connect(group_id, "wx-runtime-fail", "wechat", %{
        "tenant_id" => tenant,
        "status" => "connected",
        "wechat_id" => "wx-user",
        "token" => "wx-token",
        "base_url" => "#{base_url}",
        "updates_buf" => "buf-old"
      })

    MockProviderRuntime.wechat_body(%{
      "ret" => 0,
      "get_updates_buf" => "buf-new",
      "msgs" => [
        %{
          "client_id" => "wx-runtime-fail-message",
          "text" => "runtime wechat fail",
          "context_token" => "ctx-runtime-fail"
        }
      ]
    })

    assert {:error, :router_not_configured} = SalixIM.ProviderRuntime.poll_connect(connect)

    assert {:ok, updated} =
             SalixIM.ProviderConnects.get_active_connect_by_id(
               group_id,
               "wx-runtime-fail",
               "wechat"
             )

    assert updated["updates_buf"] == "buf-old"
    assert updated["latest_context_token"] == "ctx-runtime-fail"
    assert fake_records_with_prefix("ctl/im_wechat_event_receipts/wx-runtime-fail/") == %{}
  end

  test "disabled external connects reject provider inbound without enqueueing",
       %{tenant: tenant, group_id: group_id, agent_id: agent_id} do
    slack_secret = "slack-secret"

    slack =
      seed_connect(group_id, "sl-disabled-inbound", "slack", %{
        "tenant_id" => tenant,
        "app_id" => "A-disabled",
        "signing_secret" => slack_secret,
        "workspace_id" => "T-disabled",
        "bot_token" => "xoxb-test",
        "bot_user_id" => "Ubot",
        "oauth_completed_at" => 1,
        "disabled_at" => 123
      })

    # A mention an enabled connect would accept, so only the disable gate can
    # ignore it.
    slack_envelope = %{
      "type" => "event_callback",
      "api_app_id" => "A-disabled",
      "team_id" => "T-disabled",
      "event_id" => "Ev-disabled",
      "event" => %{
        "type" => "app_mention",
        "user" => "U1",
        "text" => "<@Ubot> blocked slack",
        "channel" => "C1",
        "channel_type" => "channel",
        "ts" => "123.456"
      }
    }

    slack_raw = Jason.encode!(slack_envelope)

    assert {:error, :ignored} =
             SalixIM.ProviderHTTP.handle_slack_event(
               slack,
               slack_envelope,
               sign_slack_body(slack_raw, slack_secret),
               slack_raw
             )

    assert fake_records_with_prefix("ctl/im_slack_event_receipts/sl-disabled-inbound/") == %{}

    feishu =
      seed_connect(group_id, "fs-disabled-inbound", "feishu", %{
        "tenant_id" => tenant,
        "app_id" => "cli_disabled",
        "app_secret" => "secret",
        "verification_token" => "verify-token",
        "status" => "connected",
        "disabled_at" => 123
      })

    feishu_envelope = %{
      "schema" => "2.0",
      "header" => %{"token" => "verify-token", "app_id" => "cli_disabled"},
      "event" => %{
        "message" => %{
          "message_id" => "om_disabled",
          "chat_id" => "oc_disabled",
          "message_type" => "text",
          "content" => Jason.encode!(%{"text" => "blocked feishu"})
        }
      }
    }

    assert {:error, :not_found} =
             SalixIM.ProviderHTTP.handle_feishu_event(
               feishu,
               feishu_envelope,
               [],
               Jason.encode!(feishu_envelope)
             )

    telegram =
      seed_connect(group_id, "tg-disabled-inbound", "telegram", %{
        "tenant_id" => tenant,
        "status" => "connected",
        "bot_token" => "123:abc",
        "bot_user_id" => "900",
        "disabled_at" => 123
      })

    assert {:error, :not_found} =
             SalixIM.ProviderHTTP.handle_telegram_update(telegram, %{
               "update_id" => 202,
               "message" => %{
                 "message_id" => 1,
                 "text" => "blocked telegram",
                 "chat" => %{"id" => 1},
                 "from" => %{"id" => 2}
               }
             })

    wechat =
      seed_connect(group_id, "wx-disabled-inbound", "wechat", %{
        "tenant_id" => tenant,
        "status" => "connected",
        "wechat_id" => "wx-disabled",
        "token" => "wx-token",
        "base_url" => "https://clawbot.example",
        "disabled_at" => 123
      })

    assert {:error, :not_found} =
             SalixIM.ProviderHTTP.handle_wechat_update(wechat, %{
               "client_id" => "wx-disabled-message",
               "text" => "blocked wechat",
               "context_token" => "ctx-disabled"
             })

    {:ok, session_id} = SalixIM.ProviderConnects.agent_group_router_session_id(agent_id, group_id)
    assert {:error, :not_found} = SalixAgent.TestSupport.SessionData.read(agent_id, session_id)
    assert fake_records_with_prefix(Keys.ctl_group_conversations_prefix(group_id)) == %{}
    assert fake_records_with_prefix("ctl/bridge_conversations/#{tenant}/") == %{}
  end
end
