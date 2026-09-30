defmodule AlertRouter.Web.Router do
  @moduledoc "Bounded HTTP ingress for authenticated source lifecycle events."

  use Plug.Router

  alias AlertRouter.Adapters.{GCPMonitoring, GitHubActions, Grafana}
  alias AlertRouter.Web.{GitHubHMAC, GrafanaHMAC}

  @max_body_bytes 1_000_000

  plug(:match)
  plug(:dispatch)

  get "/live" do
    send_resp(conn, 200, "live")
  end

  get "/ready" do
    case Ecto.Adapters.SQL.query(AlertRouter.Repo, "SELECT 1", []) do
      {:ok, _result} -> send_resp(conn, 200, "ready")
      {:error, _reason} -> send_resp(conn, 503, "not ready")
    end
  end

  post "/v1/events/slack" do
    with {:ok, body, conn} <- read_full_body(conn),
         :ok <- AlertRouter.Web.SlackSignature.verify(conn, body),
         {:ok, payload} <- Jason.decode(body) do
      case payload do
        %{"type" => "url_verification", "challenge" => challenge} when is_binary(challenge) ->
          send_json(conn, 200, %{"challenge" => challenge})

        _ ->
          case AlertRouter.Slack.Progress.accept(payload) do
            {:ok, disposition} -> send_json(conn, 200, %{"disposition" => to_string(disposition)})
            {:error, :unauthorized} -> send_json(conn, 403, %{"error" => "unauthorized"})
            {:error, _} -> send_json(conn, 503, %{"error" => "progress_unavailable"})
          end
      end
    else
      {:error, :unauthorized} -> send_json(conn, 401, %{"error" => "unauthorized"})
      _ -> send_json(conn, 400, %{"error" => "invalid_payload"})
    end
  end

  post "/v1/interactions/slack" do
    with {:ok, body, conn} <- read_full_body(conn),
         :ok <- AlertRouter.Web.SlackSignature.verify(conn, body),
         %{"payload" => encoded} <- URI.decode_query(body),
         {:ok, payload} <- Jason.decode(encoded) do
      case AlertRouter.Slack.Interactions.accept(payload) do
        {:ok, result} when result in [:stale_card, :already_owned, :not_owner] ->
          send_json(conn, 409, %{"error" => to_string(result)})

        {:ok, _} ->
          send_resp(conn, 200, "")

        {:error, :unauthorized} ->
          send_json(conn, 403, %{"error" => "unauthorized"})

        {:error, _} ->
          send_json(conn, 503, %{"error" => "interaction_unavailable"})
      end
    else
      {:error, :unauthorized} -> send_json(conn, 401, %{"error" => "unauthorized"})
      _ -> send_json(conn, 400, %{"error" => "invalid_payload"})
    end
  end

  post "/v1/events/gcp" do
    with :ok <- gcp_auth().authorize(conn),
         {:ok, raw_body, conn} <- read_full_body(conn),
         {:ok, envelope} <- Jason.decode(raw_body),
         {:ok, payload, opts} <- decode_pubsub(envelope),
         {:ok, event} <- GCPMonitoring.normalize(payload, opts),
         {:ok, result} <- AlertRouter.ingest(event) do
      send_json(conn, 202, %{"disposition" => Atom.to_string(result.disposition)})
    else
      {:error, :unauthorized} -> send_json(conn, 401, %{"error" => "unauthorized"})
      {:error, :unavailable} -> send_json(conn, 503, %{"error" => "authentication_unavailable"})
      {:error, reason} -> send_json(conn, error_status(reason), %{"error" => error_code(reason)})
    end
  end

  post "/v1/events/runtime-storage" do
    with :ok <- AlertRouter.Web.GCPPushAuth.OIDC.authorize(conn, :runtime_storage_push),
         {:ok, config} <- AlertRouter.RuntimeLog.config(),
         {:ok, raw_body, conn} <- read_full_body(conn),
         {:ok, envelope} <- Jason.decode(raw_body),
         {:ok, result} <- enqueue_runtime_notification(envelope, config) do
      send_json(conn, 202, %{"disposition" => result})
    else
      {:error, :unauthorized} -> send_json(conn, 401, %{"error" => "unauthorized"})
      {:error, _} -> send_json(conn, 503, %{"error" => "runtime_notification_unavailable"})
    end
  end

  post "/v1/events/grafana" do
    with {:ok, raw_body, conn} <- read_full_body(conn),
         :ok <- GrafanaHMAC.verify(conn, raw_body),
         {:ok, payload} <- Jason.decode(raw_body),
         {:ok, events} <- Grafana.normalize(payload, DateTime.utc_now()),
         {:ok, dispositions} <- ingest_all(events) do
      send_json(conn, 202, %{"dispositions" => Enum.map(dispositions, &Atom.to_string/1)})
    else
      {:error, reason} -> send_json(conn, error_status(reason), %{"error" => error_code(reason)})
    end
  end

  post "/v1/events/github" do
    with {:ok, raw_body, conn} <- read_full_body(conn),
         {:ok, event} <- GitHubHMAC.verify(conn, raw_body) do
      handle_github_event(conn, event, raw_body)
    else
      {:error, reason} -> send_json(conn, error_status(reason), %{"error" => error_code(reason)})
    end
  end

  post "/v1/events/posthog" do
    with :ok <- AlertRouter.Web.PostHogAuth.authorize(conn),
         {:ok, raw_body, conn} <- read_full_body(conn),
         {:ok, payload} <- Jason.decode(raw_body),
         {:ok, event} <- AlertRouter.Adapters.PostHog.normalize(payload),
         {:ok, disposition} <- ingest_disposition(event) do
      send_json(conn, 202, %{"disposition" => Atom.to_string(disposition)})
    else
      {:error, reason} -> send_json(conn, error_status(reason), %{"error" => error_code(reason)})
    end
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  defp enqueue_runtime_notification(
         %{"message" => %{"attributes" => attrs, "messageId" => notification_id}},
         config
       )
       when is_map(attrs) and is_binary(notification_id) and byte_size(notification_id) in 1..255 do
    if attrs["bucketId"] == config[:bucket] and attrs["eventType"] == "OBJECT_FINALIZE" do
      case AlertRouter.RuntimeLog.parse_object(attrs["objectId"]) do
        {:ok, agent, session} ->
          case Oban.insert(
                 AlertRouter.Oban,
                 AlertRouter.Workers.ConsumeRuntimeLog.new(%{
                   "object" => attrs["objectId"],
                   "notification_id" => notification_id,
                   "scope" => "#{config[:environment]}:#{agent}:#{session}"
                 })
               ) do
            {:ok, _} -> {:ok, "queued"}
            {:error, reason} -> {:error, reason}
          end

        :ignored ->
          {:ok, "ignored"}
      end
    else
      {:error, :invalid_storage_notification}
    end
  end

  defp enqueue_runtime_notification(_, _), do: {:error, :invalid_storage_notification}

  defp handle_github_event(conn, "ping", _raw_body) do
    send_json(conn, 202, %{"disposition" => "ignored"})
  end

  defp handle_github_event(conn, "workflow_run", raw_body) do
    with {:ok, payload} <- Jason.decode(raw_body),
         {:ok, event} <- GitHubActions.normalize(payload),
         {:ok, disposition} <- ingest_disposition(event) do
      send_json(conn, 202, %{"disposition" => Atom.to_string(disposition)})
    else
      {:error, reason} -> send_json(conn, error_status(reason), %{"error" => error_code(reason)})
    end
  end

  defp ingest_disposition(:ignored), do: {:ok, :ignored}

  defp ingest_disposition(event) do
    case AlertRouter.ingest(event) do
      {:ok, result} -> {:ok, result.disposition}
      {:error, _reason} = error -> error
    end
  end

  defp ingest_all(events) do
    Enum.reduce_while(events, {:ok, []}, fn event, {:ok, dispositions} ->
      case AlertRouter.ingest(event) do
        {:ok, %{disposition: disposition}} ->
          {:cont, {:ok, [disposition | dispositions]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, dispositions} -> {:ok, Enum.reverse(dispositions)}
      error -> error
    end
  end

  defp decode_pubsub(%{"message" => %{"data" => data} = message}) when is_binary(data) do
    with {:ok, decoded} <- Base.decode64(data),
         {:ok, payload} <- Jason.decode(decoded),
         {:ok, published_at} <- optional_iso8601(message["publishTime"]) do
      {:ok, payload,
       [
         message_id: message["messageId"] || message["message_id"],
         observed_at: published_at
       ]}
    else
      :error -> {:error, :invalid_pubsub_data}
      {:error, _reason} = error -> error
    end
  end

  defp decode_pubsub(_envelope), do: {:error, :invalid_pubsub_envelope}

  defp optional_iso8601(nil), do: {:ok, nil}

  defp optional_iso8601(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _ -> {:error, :invalid_pubsub_publish_time}
    end
  end

  defp optional_iso8601(_value), do: {:error, :invalid_pubsub_publish_time}

  defp read_full_body(conn, acc \\ "") do
    case Plug.Conn.read_body(conn,
           length: @max_body_bytes,
           read_length: 64_000,
           read_timeout: 5_000
         ) do
      {:ok, chunk, conn} ->
        body = acc <> chunk

        if byte_size(body) <= @max_body_bytes,
          do: {:ok, body, conn},
          else: {:error, :body_too_large}

      {:more, chunk, conn} ->
        body = acc <> chunk

        if byte_size(body) <= @max_body_bytes,
          do: read_full_body(conn, body),
          else: {:error, :body_too_large}

      {:error, reason} ->
        {:error, {:body_read_failed, reason}}
    end
  end

  defp gcp_auth do
    Application.get_env(:alert_router, :gcp_push, [])
    |> Keyword.get(:auth_module, AlertRouter.Web.GCPPushAuth.DenyAll)
  end

  defp error_status(reason)
       when reason in [
              :invalid_or_stale_signature,
              :invalid_signature,
              :missing_signature_header,
              :invalid_timestamp_header
            ],
       do: 401

  defp error_status(:not_configured), do: 503
  defp error_status(:router_disabled), do: 503
  defp error_status({:route_not_configured, _route}), do: 503
  defp error_status({:unapproved_route_destination, _route, _channel}), do: 503
  defp error_status({:unapproved_route_environment, _route, _environment}), do: 503
  defp error_status({:unsupported_route_mode, _mode}), do: 503
  defp error_status({:route_change_requires_drain, _current, _incoming}), do: 409
  defp error_status(%Jason.DecodeError{}), do: 400
  defp error_status(_reason), do: 422

  defp error_code(%Jason.DecodeError{}), do: "invalid_json"
  defp error_code({code, _current, _incoming}) when is_atom(code), do: Atom.to_string(code)
  defp error_code({code, _detail}) when is_atom(code), do: Atom.to_string(code)
  defp error_code(code) when is_atom(code), do: Atom.to_string(code)
  defp error_code(_reason), do: "invalid_event"

  defp send_json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
