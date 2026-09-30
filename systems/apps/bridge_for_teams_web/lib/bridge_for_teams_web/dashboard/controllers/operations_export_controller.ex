defmodule BridgeForTeamsWeb.Dashboard.OperationsExportController do
  @moduledoc """
  Bounded CSV exports for the Operations console.

  Exports intentionally reuse the same redacted persistence/query boundary as
  the interactive Operations pages and only expose allowlisted summary columns.
  Raw audit metadata and redacted diffs stay out of CSV output.
  """
  use BridgeForTeamsWeb.Dashboard, :controller

  require Logger

  alias BridgeForTeams.{Memberships, Observability, Orgs}

  @audit_export_limit 500
  @audit_columns [
    "audit_id",
    "created_at",
    "actor_type",
    "actor_user_id",
    "action",
    "resource_type",
    "resource_id",
    "resource_label",
    "result",
    "reason_class",
    "request_id"
  ]
  @audit_filter_keys ~w(audit_log_id actor_user_id action resource_type resource_id result request_id since)

  def audit(conn, %{"org" => slug} = params) do
    user = conn.assigns.current_user

    with {:ok, org} <- Orgs.get_org_by_slug(slug),
         :ok <- authorize_audit_export(org.id, user.id) do
      rows =
        org.id
        |> Observability.list_audit_logs(audit_opts(params))
        |> Enum.map(&audit_row/1)

      csv = csv_encode([@audit_columns | rows])

      record_audit_export(org, user, params, length(rows))

      conn
      |> put_resp_content_type("text/csv")
      |> put_resp_header(
        "content-disposition",
        ~s(attachment; filename="#{audit_filename(org.slug)}")
      )
      |> send_resp(200, csv)
    else
      {:error, :not_found} ->
        conn |> put_status(:not_found) |> text("not found")

      {:error, :forbidden} ->
        conn |> put_status(:forbidden) |> text("forbidden")
    end
  end

  defp authorize_audit_export(org_id, user_id) do
    case Memberships.org_role(org_id, user_id) do
      {:ok, role} when role in ["owner", "admin"] -> :ok
      {:ok, _role} -> {:error, :forbidden}
      {:error, _reason} -> {:error, :forbidden}
    end
  end

  defp audit_opts(params) do
    params
    |> Map.take(@audit_filter_keys)
    |> Enum.reduce([limit: @audit_export_limit], fn
      {"since", since}, opts ->
        maybe_put_since(opts, since)

      {key, value}, opts ->
        case normalize_filter(value) do
          nil -> opts
          value -> Keyword.put(opts, filter_key(key), value)
        end
    end)
  end

  defp record_audit_export(org, user, params, row_count) do
    case Observability.record_audit(%{
           org_id: org.id,
           actor_user_id: user.id,
           actor_label: audit_actor_label(user),
           action: "audit_log.exported",
           resource_type: "audit_export",
           resource_id: org.id,
           resource_label: "bft-audit-#{org.slug}.csv",
           result: "ok",
           request_id: request_id(),
           metadata: %{
             "format" => "csv",
             "row_count" => row_count,
             "limit" => @audit_export_limit,
             "filter_keys" => audit_filter_keys(params),
             "columns" => @audit_columns
           }
         }) do
      {:ok, _audit} ->
        :ok

      {:error, reason} ->
        Logger.warning("audit_export_audit_failed reason=#{inspect(reason)}")
        :ok
    end
  end

  defp audit_actor_label(user) do
    cond do
      is_binary(user.email) and user.email != "" -> user.email
      is_binary(user.name) and user.name != "" -> user.name
      true -> user.id
    end
  end

  defp audit_filter_keys(params) do
    params
    |> Map.take(@audit_filter_keys)
    |> Enum.flat_map(fn {key, value} ->
      case normalize_filter(value) do
        nil -> []
        _value -> [key]
      end
    end)
    |> Enum.sort()
  end

  defp request_id do
    case Logger.metadata()[:request_id] do
      request_id when is_binary(request_id) and request_id != "" -> request_id
      _ -> Ecto.UUID.generate()
    end
  end

  defp filter_key("audit_log_id"), do: :audit_log_id
  defp filter_key("actor_user_id"), do: :actor_user_id
  defp filter_key("action"), do: :action
  defp filter_key("resource_type"), do: :resource_type
  defp filter_key("resource_id"), do: :resource_id
  defp filter_key("result"), do: :result
  defp filter_key("request_id"), do: :request_id

  defp maybe_put_since(opts, since) do
    with since when is_binary(since) and since != "" <- since,
         {:ok, datetime, _offset} <- DateTime.from_iso8601(since) do
      Keyword.put(opts, :since, datetime)
    else
      _ -> opts
    end
  end

  defp normalize_filter(nil), do: nil
  defp normalize_filter(""), do: nil
  defp normalize_filter(value), do: value

  defp audit_row(audit) do
    [
      audit.id,
      format_datetime(audit.created_at),
      audit.actor_type,
      audit.actor_user_id,
      audit.action,
      audit.resource_type,
      audit.resource_id,
      audit.resource_label,
      audit.result,
      audit.reason_class,
      audit.request_id
    ]
  end

  defp format_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp format_datetime(nil), do: ""

  defp audit_filename(slug) do
    safe_slug =
      slug
      |> to_string()
      |> String.replace(~r/[^a-zA-Z0-9_-]+/, "-")
      |> String.trim("-")

    "bft-audit-#{safe_slug}.csv"
  end

  defp csv_encode(rows) do
    rows
    |> Enum.map(fn row ->
      row
      |> Enum.map(&csv_cell/1)
      |> Enum.join(",")
    end)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp csv_cell(nil), do: ""

  defp csv_cell(value) do
    value
    |> to_string()
    |> escape_formula()
    |> String.replace("\"", "\"\"")
    |> then(&~s("#{&1}"))
  end

  defp escape_formula("=" <> _ = value), do: "'" <> value
  defp escape_formula("+" <> _ = value), do: "'" <> value
  defp escape_formula("-" <> _ = value), do: "'" <> value
  defp escape_formula("@" <> _ = value), do: "'" <> value
  defp escape_formula(<<"\t", _::binary>> = value), do: "'" <> value
  defp escape_formula(value), do: value
end
