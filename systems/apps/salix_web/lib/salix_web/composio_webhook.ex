defmodule SalixWeb.ComposioWebhook do
  @moduledoc """
  Secret-URL Composio ingress. Each matching Loop durably retains its accepted
  events. A product that reads the account itself receives the event only as
  a signal to read it now, without the event data.
  """
  import Plug.Conn
  alias SalixStore.{ComposioSettings, Loops}
  alias Salix.App.RouterInbox.RateLimit

  # The settings owner controls the random URL credential. It grants event
  # submission within that scope only. Composio signatures are not checked.
  def admit(conn) do
    with :ok <- limit("global", 6_000),
         {:ok, scope, settings} <- ComposioSettings.by_webhook_secret(List.last(conn.path_info)),
         :ok <- limit("scope:" <> scope, 600) do
      conn
      |> assign(:composio_scope, scope)
      |> assign(:composio_settings, settings)
      |> put_resp_header("cache-control", "no-store")
    else
      {:error, :not_found} -> reply(conn, 404, %{error: "not_found"}) |> halt()
      {:error, :rate_limited} -> retry(conn, 429, "rate_limited") |> halt()
      _ -> reply(conn, 503, %{error: "unavailable"}) |> halt()
    end
  end

  def receive_event(conn) do
    cond do
      conn.assigns[:raw_body_too_large] == true -> reply(conn, 413, %{error: "payload_too_large"})
      not json?(conn) -> reply(conn, 415, %{error: "json_required"})
      true -> route(conn, conn.body_params)
    end
  end

  defp route(conn, %{
         "type" => "composio.trigger.message",
         "id" => id,
         "metadata" => metadata,
         "data" => data
       })
       when is_map(metadata) and is_map(data) do
    with true <-
           valid?(id, 128) and valid?(metadata["trigger_slug"], 128) and
             Enum.all?(
               ~w(user_id trigger_id trigger_slug connected_account_id),
               &valid?(metadata[&1], 256)
             ),
         group <- metadata["user_id"],
         {:ok, group_record} <- Salix.Control.Groups.get(group),
         {:ok, effective} <- Salix.Control.ComposioSettings.get(group_record["tenant_id"]),
         true <- effective["scope"] == conn.assigns.composio_scope,
         {:ok, account} <-
           client().get_connected_account(
             conn.assigns.composio_settings,
             metadata["connected_account_id"],
             error_mode: :structured
           ),
         true <- account["user_id"] == group and account["status"] == "ACTIVE",
         :ok <- limit("group:" <> group, 60),
         {:ok, rows} <- Loops.composio_subscribers(group, metadata["trigger_id"]) do
      rows =
        Enum.filter(rows, fn row ->
          b = row["composio_trigger"]

          row["tenant_id"] == group_record["tenant_id"] and b["scope"] == effective["scope"] and
            b["connected_account_id"] == metadata["connected_account_id"] and
            b["trigger_slug"] == metadata["trigger_slug"]
        end)

      event = %{"event_id" => id, "topic" => metadata["trigger_slug"], "payload" => data}
      # At most 100 active subscribers per Group. Each batch has 20 workers,
      # and each owner call has the existing five-second delivery deadline.
      results =
        rows
        |> Task.async_stream(
          fn row ->
            SalixAgent.Loops.deliver_composio_event(row["id"], row["composio_trigger"], event)
          end,
          max_concurrency: 20,
          timeout: 6_000,
          on_timeout: :kill_task
        )
        |> Enum.to_list()

      signaled = signal(group, metadata)

      cond do
        Enum.any?(results, &match?({:ok, {:error, :mailbox_full}}, &1)) ->
          retry(conn, 429, "mailbox_full")

        Enum.any?(results, &failed?/1) or not match?({:ok, _}, signaled) ->
          retry(conn, 503, "delivery_unavailable")

        true ->
          {:ok, readers} = signaled

          reply(conn, 202, %{
            status: "accepted",
            event_id: id,
            subscribers: length(rows) + readers
          })
      end
    else
      false -> reply(conn, 422, %{error: "invalid_event_scope"})
      {:error, :not_found} -> reply(conn, 404, %{error: "not_found"})
      {:error, :rate_limited} -> retry(conn, 429, "rate_limited")
      _ -> retry(conn, 503, "unavailable")
    end
  end

  defp route(conn, _), do: reply(conn, 422, %{error: "expected_v3_trigger_event"})

  # Comma's member source item pool reads the named account again through its
  # official API. It gets the trigger and account, never the event data.
  defp signal(group, metadata) do
    case Application.get_env(:salix_web, :composio_signal_mod) do
      module when is_atom(module) and not is_nil(module) ->
        module.signal(group, metadata["trigger_id"], metadata["connected_account_id"])

      _ ->
        {:ok, 0}
    end
  end

  defp failed?({:ok, {:ok, _}}), do: false
  defp failed?({:ok, {:error, :not_found}}), do: false
  defp failed?({:ok, {:error, :binding_changed}}), do: false
  defp failed?({:ok, {:error, {:not_active, _}}}), do: false
  defp failed?(_), do: true
  defp valid?(s, max), do: is_binary(s) and byte_size(s) > 0 and byte_size(s) <= max

  defp json?(conn),
    do:
      Enum.any?(
        get_req_header(conn, "content-type"),
        &(String.downcase(hd(String.split(&1, ";"))) == "application/json")
      )

  defp limit(bucket, count) do
    case RateLimit.hit("composio-webhook:" <> bucket, 60_000, count) do
      {:allow, _} -> :ok
      {:deny, _} -> {:error, :rate_limited}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp retry(conn, status, error),
    do: conn |> put_resp_header("retry-after", "5") |> reply(status, %{error: error})

  defp reply(conn, status, body),
    do:
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(body))

  defp client, do: Application.get_env(:salix_web, :composio_client_mod, SalixStore.Composio)
end
