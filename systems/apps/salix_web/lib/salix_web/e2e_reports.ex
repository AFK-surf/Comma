defmodule SalixWeb.E2EReports do
  @moduledoc """
  Admin-facing access to Playwright E2E report bundles stored in R2.

  The dashboard never receives R2 credentials. Admin routes list and clean up
  metadata through the normal Salix bearer token, while report browsing uses a
  short-lived token scoped to one run/attempt/target report prefix.
  """

  @prefix "e2e-reports"
  @default_days 30
  @max_days 35
  @default_limit 100
  @max_limit 500

  @public_session_ttl_seconds 60 * 60
  @max_session_ttl_seconds 6 * 60 * 60

  def list_runs(params \\ %{}) do
    params = normalize_params(params)
    days = params |> get_param("days", @default_days) |> parse_int(@default_days)
    days = days |> max(1) |> min(@max_days)
    limit = params |> get_param("limit", @default_limit) |> parse_int(@default_limit)
    limit = limit |> max(1) |> min(@max_limit)

    runs =
      days
      |> index_dates()
      |> Enum.flat_map(&read_index_date/1)
      |> Enum.uniq_by(&{field(&1, "runId"), field(&1, "attempt")})
      |> Enum.filter(&matches_filters?(&1, params))
      |> Enum.sort_by(&(field(&1, "finishedAt") || ""), :desc)
      |> Enum.take(limit)

    {:ok, runs}
  end

  def get_run(run_id, attempt \\ nil) do
    with {:ok, attempt} <- resolve_attempt(run_id, attempt),
         {:ok, run} <- get_json(run_key(run_id, attempt)) do
      {:ok, run}
    end
  end

  def list_artifacts(params \\ %{}) do
    params = normalize_params(params)

    with {:ok, runs} <- list_runs(params) do
      artifacts =
        runs
        |> Enum.flat_map(&run_artifacts/1)
        |> Enum.filter(&artifact_matches_filters?(&1, params))
        |> Enum.take(parse_int(get_param(params, "limit", @default_limit), @default_limit))

      {:ok, artifacts}
    end
  end

  def create_report_session(params) do
    params = normalize_params(params)
    run_id = get_param(params, "runId") || get_param(params, "run_id")
    attempt = get_param(params, "attempt")
    target = get_param(params, "target")

    ttl =
      params
      |> get_param("ttlSeconds", @public_session_ttl_seconds)
      |> parse_int(@public_session_ttl_seconds)

    ttl = ttl |> max(60) |> min(@max_session_ttl_seconds)

    with :ok <- require_binary(run_id, "runId"),
         :ok <- require_binary(attempt, "attempt"),
         :ok <- require_binary(target, "target"),
         {:ok, run} <- get_run(run_id, attempt),
         {:ok, target_record} <- target_record(run, target),
         {:ok, token, expires_at} <-
           sign_session(%{
             "runId" => run_id,
             "attempt" => to_string(attempt),
             "target" => target,
             "root" => field(target_record, "reportRootKey"),
             "exp" => System.system_time(:second) + ttl
           }) do
      {:ok,
       %{
         token: token,
         expiresAt: expires_at,
         url: "/v1/e2e-report-sessions/#{token}/index.html"
       }}
    end
  end

  def serve_report_file(token, path) do
    with {:ok, session} <- verify_session(token),
         {:ok, safe_path} <- safe_report_path(path),
         {:ok, root} <- session_root(session) do
      key = root <> "/" <> safe_path

      case storage().get_object(key) do
        {:ok, %{body: body}} ->
          {:ok, %{body: body, content_type: content_type(safe_path)}}

        {:error, :not_found} ->
          {:error, :not_found}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def cleanup_preview(params \\ %{}) do
    params = normalize_params(params)

    with {:ok, runs} <- cleanup_runs(params),
         {:ok, objects} <- objects_for_runs(runs) do
      {:ok,
       %{
         filters: params,
         runs: Enum.map(runs, &run_summary/1),
         objectCount: length(objects),
         totalBytes: Enum.reduce(objects, 0, &(&2 + object_size(&1))),
         objects: objects
       }}
    end
  end

  def cleanup(params \\ %{}) do
    params = normalize_params(params)

    if get_param(params, "confirm") == true do
      with {:ok, preview} <- cleanup_preview(params) do
        delete_results =
          Enum.map(preview.objects, fn object ->
            key = field(object, "key")

            case confined_key(key) do
              {:ok, ^key} ->
                case storage().delete_object(key) do
                  :ok -> %{key: key, status: "deleted"}
                  {:error, reason} -> %{key: key, status: "error", error: inspect(reason)}
                end

              {:error, reason} ->
                %{key: key, status: "error", error: inspect(reason)}
            end
          end)

        errors = Enum.filter(delete_results, &(field(&1, "status") != "deleted"))

        result =
          preview
          |> Map.put(
            :deletedObjects,
            Enum.count(delete_results, &(field(&1, "status") == "deleted"))
          )
          |> Map.put(:deleteResults, delete_results)

        if errors == [] do
          {:ok, result}
        else
          {:error, {:partial_failure, Map.put(result, :errors, errors)}}
        end
      end
    else
      {:error, :confirmation_required}
    end
  end

  def delete_run(run_id, attempt) do
    cleanup(%{"confirm" => true, "runs" => [%{"runId" => run_id, "attempt" => attempt}]})
  end

  defp cleanup_runs(%{"runs" => runs}) when is_list(runs) do
    runs
    |> Enum.reduce_while({:ok, []}, fn run, {:ok, acc} ->
      run = normalize_params(run)
      run_id = get_param(run, "runId") || get_param(run, "run_id")
      attempt = get_param(run, "attempt")

      case get_run(run_id, attempt) do
        {:ok, record} -> {:cont, {:ok, [record | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      other -> other
    end
  end

  defp cleanup_runs(params) do
    if truthy?(get_param(params, "retention")) do
      {:ok, runs} =
        params
        |> Map.put("days", @max_days)
        |> Map.put("limit", @max_limit)
        |> list_runs()

      {:ok, Enum.filter(runs, &expired?/1)}
    else
      list_runs(params)
    end
  end

  defp objects_for_runs(runs) do
    Enum.reduce_while(runs, {:ok, []}, fn run, {:ok, acc} ->
      run_prefix = run_prefix(field(run, "runId"), field(run, "attempt"))

      with {:ok, objects} <- storage().list_objects(run_prefix) do
        all_objects =
          [index_object(run) | objects]
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq_by(&field(&1, "key"))

        case Enum.find(all_objects, fn object ->
               match?({:error, _}, confined_key(field(object, "key")))
             end) do
          nil -> {:cont, {:ok, acc ++ all_objects}}
          object -> {:halt, confined_key(field(object, "key"))}
        end
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp run_artifacts(run) do
    targets = field(run, "targets") || %{}

    Enum.flat_map(targets, fn {target, target_record} ->
      target_record = normalize_params(target_record)

      Enum.map(field(target_record, "artifacts") || [], fn artifact ->
        artifact = normalize_params(artifact)

        artifact
        |> Map.put("runId", field(run, "runId"))
        |> Map.put("attempt", field(run, "attempt"))
        |> Map.put("status", field(run, "status"))
        |> Map.put("branch", field(run, "branch"))
        |> Map.put("prNumber", field(run, "prNumber"))
        |> Map.put("target", to_string(target))
        |> Map.put("finishedAt", field(run, "finishedAt"))
      end)
    end)
  end

  defp read_index_date(date) do
    prefix = "#{@prefix}/index/#{date}/"

    with {:ok, objects} <- storage().list_objects(prefix) do
      objects
      |> Enum.flat_map(fn object ->
        case get_json(field(object, "key")) do
          {:ok, run} -> [run]
          _ -> []
        end
      end)
    else
      _ -> []
    end
  end

  defp resolve_attempt(_run_id, attempt) when is_binary(attempt) and attempt != "" do
    {:ok, attempt}
  end

  defp resolve_attempt(run_id, _attempt) do
    with {:ok, objects} <- storage().list_objects("#{@prefix}/runs/#{run_id}/") do
      attempt =
        objects
        |> Enum.map(&field(&1, "key"))
        |> Enum.filter(&String.ends_with?(&1, "/run.json"))
        |> Enum.map(fn key ->
          key
          |> String.trim_leading("#{@prefix}/runs/#{run_id}/")
          |> String.split("/", parts: 2)
          |> List.first()
        end)
        |> Enum.max_by(&parse_int(&1, 0), fn -> nil end)

      if attempt, do: {:ok, attempt}, else: {:error, :not_found}
    end
  end

  defp get_json(key) do
    case storage().get_object(key) do
      {:ok, %{body: body}} when is_binary(body) -> Jason.decode(body)
      {:ok, body} when is_binary(body) -> Jason.decode(body)
      {:ok, map} when is_map(map) -> {:ok, map}
      {:error, reason} -> {:error, reason}
    end
  end

  defp matches_filters?(run, params) do
    status = get_param(params, "status")

    (blank?(status) or field(run, "status") == status) and
      target_matches?(run, get_param(params, "target")) and
      blank_or_equal?(get_param(params, "branch"), field(run, "branch")) and
      blank_or_equal?(get_param(params, "pr"), field(run, "prNumber")) and
      before_matches?(field(run, "finishedAt"), get_param(params, "before"))
  end

  defp artifact_matches_filters?(artifact, params) do
    blank_or_equal?(get_param(params, "status"), field(artifact, "status")) and
      blank_or_equal?(get_param(params, "target"), field(artifact, "target")) and
      blank_or_equal?(get_param(params, "branch"), field(artifact, "branch")) and
      blank_or_equal?(get_param(params, "pr"), field(artifact, "prNumber")) and
      before_matches?(field(artifact, "finishedAt"), get_param(params, "before"))
  end

  defp target_matches?(_run, target) when target in [nil, ""], do: true

  defp target_matches?(run, target) do
    targets = field(run, "targets") || %{}
    Enum.any?(Map.keys(targets), &(to_string(&1) == to_string(target)))
  end

  defp before_matches?(_finished_at, before) when before in [nil, ""], do: true
  defp before_matches?(nil, _before), do: false
  defp before_matches?(finished_at, before), do: to_string(finished_at) < to_string(before)

  defp expired?(run) do
    status = field(run, "status")
    retention_days = if status == "success", do: 7, else: 30

    threshold =
      DateTime.utc_now()
      |> DateTime.add(-retention_days * 86_400, :second)
      |> DateTime.to_iso8601()

    before_matches?(field(run, "finishedAt"), threshold)
  end

  defp blank_or_equal?(expected, _actual) when expected in [nil, ""], do: true
  defp blank_or_equal?(expected, actual), do: to_string(actual) == to_string(expected)

  defp target_record(run, target) do
    targets = field(run, "targets") || %{}

    case Enum.find_value(targets, fn {key, value} ->
           if to_string(key) == to_string(target), do: value
         end) do
      nil -> {:error, :not_found}
      record -> {:ok, record}
    end
  end

  defp session_root(session) do
    root = field(session, "root")

    case confined_key(root) do
      {:ok, ^root} ->
        if String.contains?(root, "/report"), do: {:ok, root}, else: {:error, :invalid_scope}

      other ->
        other
    end
  end

  defp sign_session(payload) do
    case session_secret() do
      nil ->
        {:error, :session_secret_missing}

      secret ->
        body = Jason.encode!(payload)
        encoded = Base.url_encode64(body, padding: false)
        signature = sign(encoded, secret)
        token = encoded <> "." <> signature
        {:ok, token, DateTime.from_unix!(payload["exp"]) |> DateTime.to_iso8601()}
    end
  end

  defp verify_session(token) when is_binary(token) do
    with [encoded, signature] <- String.split(token, ".", parts: 2),
         secret when is_binary(secret) <- session_secret(),
         true <- Plug.Crypto.secure_compare(signature, sign(encoded, secret)),
         {:ok, body} <- Base.url_decode64(encoded, padding: false),
         {:ok, payload} <- Jason.decode(body),
         true <- parse_int(field(payload, "exp"), 0) > System.system_time(:second) do
      {:ok, payload}
    else
      _ -> {:error, :invalid_token}
    end
  end

  defp verify_session(_token), do: {:error, :invalid_token}

  defp sign(value, secret) do
    :crypto.mac(:hmac, :sha256, secret, value)
    |> Base.url_encode64(padding: false)
  end

  defp session_secret do
    Application.get_env(:salix_web, :e2e_reports_session_secret)
  end

  defp safe_report_path(path) when is_list(path), do: safe_report_path(Enum.join(path, "/"))
  defp safe_report_path(""), do: {:ok, "index.html"}
  defp safe_report_path(nil), do: {:ok, "index.html"}

  defp safe_report_path(path) when is_binary(path) do
    normalized = URI.decode(path)

    cond do
      String.starts_with?(normalized, "/") -> {:error, :invalid_path}
      String.contains?(normalized, "\\") -> {:error, :invalid_path}
      normalized |> String.split("/") |> Enum.any?(&(&1 in ["..", ""])) -> {:error, :invalid_path}
      true -> {:ok, normalized}
    end
  end

  defp safe_report_path(_), do: {:error, :invalid_path}

  defp confined_key(key) when is_binary(key) do
    if String.starts_with?(key, @prefix <> "/"), do: {:ok, key}, else: {:error, :outside_prefix}
  end

  defp confined_key(_key), do: {:error, :outside_prefix}

  defp run_summary(run) do
    %{
      runId: field(run, "runId"),
      attempt: field(run, "attempt"),
      status: field(run, "status"),
      branch: field(run, "branch"),
      prNumber: field(run, "prNumber"),
      finishedAt: field(run, "finishedAt")
    }
  end

  defp index_object(run) do
    key =
      field(run, "indexKey") ||
        "#{@prefix}/index/#{String.slice(to_string(field(run, "finishedAt")), 0, 10)}/#{field(run, "runId")}-#{field(run, "attempt")}.json"

    %{key: key, size: 0}
  end

  defp index_dates(days) do
    today = Date.utc_today()

    for offset <- 0..(days - 1) do
      today |> Date.add(-offset) |> Date.to_iso8601()
    end
  end

  defp run_key(run_id, attempt), do: "#{run_prefix(run_id, attempt)}run.json"
  defp run_prefix(run_id, attempt), do: "#{@prefix}/runs/#{run_id}/#{attempt}/"

  defp content_type(path) do
    case path |> Path.extname() |> String.downcase() do
      ".css" -> "text/css; charset=utf-8"
      ".gif" -> "image/gif"
      ".html" -> "text/html; charset=utf-8"
      ".jpeg" -> "image/jpeg"
      ".jpg" -> "image/jpeg"
      ".js" -> "text/javascript; charset=utf-8"
      ".json" -> "application/json; charset=utf-8"
      ".map" -> "application/json; charset=utf-8"
      ".mov" -> "video/quicktime"
      ".mp4" -> "video/mp4"
      ".png" -> "image/png"
      ".svg" -> "image/svg+xml"
      ".txt" -> "text/plain; charset=utf-8"
      ".webm" -> "video/webm"
      ".webp" -> "image/webp"
      ".zip" -> "application/zip"
      _ -> "application/octet-stream"
    end
  end

  defp storage do
    Application.get_env(:salix_web, :e2e_reports_storage, SalixWeb.E2EReports.R2)
  end

  defp normalize_params(params) when is_map(params) do
    Map.new(params, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {to_string(key), value}
    end)
  end

  defp normalize_params(_), do: %{}

  defp get_param(map, key, default \\ nil), do: Map.get(map, key, default)

  defp parse_int(value, _default) when is_integer(value), do: value

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> default
    end
  end

  defp parse_int(_value, default), do: default

  defp require_binary(value, _field) when is_binary(value) and value != "", do: :ok
  defp require_binary(_value, field), do: {:error, {:missing, field}}

  defp blank?(value), do: value in [nil, ""]

  defp truthy?(value), do: value in [true, "true", "1", "yes", "on"]

  defp object_size(object), do: parse_int(field(object, "size"), 0)

  defp field(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        Enum.find_value(map, fn
          {atom_key, value} when is_atom(atom_key) ->
            if Atom.to_string(atom_key) == key, do: value

          _ ->
            nil
        end)
    end
  end

  defp field(_map, _key), do: nil
end
