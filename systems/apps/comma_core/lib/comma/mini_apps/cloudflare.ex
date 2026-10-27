defmodule Comma.MiniApps.Cloudflare do
  @moduledoc """
  The Cloudflare Workers for Platforms adapter: the only module that speaks
  the Cloudflare REST API for Mini Apps.

    * `upload_version/3`: one Version's backend as script `app-<slug>-v<n>` in
      the dispatch namespace, with the `STORAGE` Durable Object binding to the
      app's storage script, each owner secret as a `secret_text` binding, and
      the CPU limit (design §8);
    * `upload_data_script/1`: the app's storage script `app-<slug>-data`,
      which holds the Comma-owned `AppStorage` class (SQLite);
    * `delete_script/1`.

  The API token stays in server config. `config :comma_core,
  :mini_apps_cloudflare_http_options` merges into each request (tests point
  it at a stub). The `AppStorage` module is compiled in from
  `priv/mini_apps/app-storage.js`, the dispatch Worker's build
  (`npm run build:storage` in `systems/cloudflare/miniapp-dispatch`).
  `app_storage_module_path` replaces it when set.
  """

  require Logger

  alias Comma.MiniApps.Config

  @api "https://api.cloudflare.com/client/v4"
  @timeout_ms 30_000
  @compatibility_date "2025-09-01"
  @cpu_ms 50

  @app_storage_path Path.expand("../../../priv/mini_apps/app-storage.js", __DIR__)
  @external_resource @app_storage_path
  @app_storage_source File.read!(@app_storage_path)

  def version_script(slug, number), do: "app-#{slug}-v#{number}"
  def data_script(slug), do: "app-#{slug}-data"

  @doc """
  Uploads a Version script. `app` names the slug; `secrets` maps names to
  plain values.
  """
  def upload_version(%{slug: slug}, number, %{source: source, secrets: secrets})
      when is_binary(source) do
    with {:ok, config} <- Config.cloudflare() do
      metadata = %{
        "main_module" => "index.js",
        "compatibility_date" => @compatibility_date,
        "bindings" =>
          [
            %{
              "type" => "durable_object_namespace",
              "name" => "STORAGE",
              "class_name" => "AppStorage",
              "script_name" => data_script(slug),
              "dispatch_namespace" => config.namespace
            }
          ] ++
            Enum.map(Enum.sort(secrets), fn {name, value} ->
              %{"type" => "secret_text", "name" => name, "text" => value}
            end),
        "limits" => %{"cpu_ms" => @cpu_ms},
        "observability" => %{"enabled" => true},
        "tags" => ["app-" <> slug]
      }

      upload(version_script(slug, number), metadata, "index.js", source)
    end
  end

  @doc "Uploads the app's storage script with the `AppStorage` class."
  def upload_data_script(%{slug: slug}) do
    with {:ok, source} <- app_storage_source() do
      metadata = %{
        "main_module" => "app-storage.js",
        "compatibility_date" => @compatibility_date,
        "tags" => ["app-" <> slug]
      }

      first =
        Map.put(metadata, "migrations", %{
          "new_tag" => "v1",
          "new_sqlite_classes" => ["AppStorage"]
        })

      # The class migration applies once. A script that has it already (an
      # upload whose answer was lost) refuses it again; it is then uploaded as is.
      case upload(data_script(slug), first, "app-storage.js", source) do
        {:error, {:cloudflare, status, message}} when status in 400..499 ->
          if message =~ ~r/migration/i,
            do: upload(data_script(slug), metadata, "app-storage.js", source),
            else: {:error, {:cloudflare, status, message}}

        result ->
          result
      end
    end
  end

  @doc "Deletes a script; one that does not exist is deleted already."
  def delete_script(name) do
    with {:ok, config} <- Config.cloudflare() do
      case request(config, :delete, script_path(config, name), params: [force: true]) do
        {:ok, _body} -> :ok
        {:error, {:cloudflare, 404, _}} -> :ok
        error -> error
      end
    end
  end

  defp upload(name, metadata, module_name, source) do
    with {:ok, config} <- Config.cloudflare() do
      form = [
        {:metadata,
         {Jason.encode!(metadata), filename: "metadata.json", content_type: "application/json"}},
        {module_field(module_name),
         {source, filename: module_name, content_type: "application/javascript+module"}}
      ]

      case request(config, :put, script_path(config, name), form_multipart: form) do
        {:ok, _body} -> :ok
        error -> error
      end
    end
  end

  # Req names multipart fields by atom; the two module names are fixed.
  defp module_field("index.js"), do: :"index.js"
  defp module_field("app-storage.js"), do: :"app-storage.js"

  defp app_storage_source do
    case Config.get(:app_storage_module_path) do
      path when is_binary(path) ->
        case File.read(path) do
          {:ok, source} -> {:ok, source}
          {:error, _} -> {:error, :app_storage_module_missing}
        end

      _ ->
        {:ok, @app_storage_source}
    end
  end

  defp script_path(config, name) do
    "/accounts/#{seg(config.account_id)}/workers/dispatch/namespaces/" <>
      "#{seg(config.namespace)}/scripts/#{seg(name)}"
  end

  defp request(config, method, path, opts) do
    [
      method: method,
      url: @api <> path,
      auth: {:bearer, config.api_token},
      retry: false,
      redirect: false,
      receive_timeout: @timeout_ms,
      pool_timeout: @timeout_ms,
      connect_options: [timeout: @timeout_ms]
    ]
    |> Keyword.merge(opts)
    |> Keyword.merge(SystemsRuntime.get_env(:comma_core, :mini_apps_cloudflare_http_options, []))
    |> Req.request()
    |> case do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        message = cloudflare_message(body)
        Logger.warning("mini app cloudflare: #{method} answered #{status}: #{message}")
        {:error, {:cloudflare, status, message}}

      {:error, reason} ->
        Logger.warning("mini app cloudflare: #{method} failed: #{Exception.message(reason)}")
        {:error, :cloudflare_unavailable}
    end
  end

  defp cloudflare_message(%{"errors" => [%{"message" => message} | _]}) when is_binary(message),
    do: message

  defp cloudflare_message(_body), do: "Cloudflare refused the request"

  defp seg(value), do: URI.encode(to_string(value), &URI.char_unreserved?/1)
end
