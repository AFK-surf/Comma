defmodule Mix.Tasks.Salix.Vm.CloudflarePreflight do
  @moduledoc """
  Preflight the deployment-wide Cloudflare VM default provider.

  Checks:

    * platform/default VM config exists and defaults to `cloudflare`;
    * Cloudflare provider credentials are present;
    * gateway `/healthz` responds;
    * with `--sandbox-id ID`, signed status/ensure/destroy calls work for a
      disposable sandbox id.

  The sandbox probe is opt-in because it can allocate provider resources.
  """

  use Mix.Task

  alias SalixEnv.VM.Providers.Cloudflare.Client

  @shortdoc "Preflight Cloudflare VM default-provider readiness"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, _invalid} =
      OptionParser.parse(args,
        strict: [sandbox_id: :string, keep: :boolean],
        aliases: [s: :sandbox_id]
      )

    with {:ok, config} <- platform_config(),
         :ok <- check_default_provider(config),
         {:ok, section} <- cloudflare_section(config),
         :ok <- check_health(section),
         :ok <- maybe_probe_sandbox(section, opts) do
      Mix.shell().info("Cloudflare VM preflight passed")
    else
      {:error, reason} ->
        Mix.raise("Cloudflare VM preflight failed: #{format_reason(reason)}")
    end
  end

  defp platform_config do
    case SalixWeb.CloudVM.default_vm_config() do
      {:ok, config} ->
        {:ok, config}

      _ ->
        case Application.get_env(:salix_web, :platform_vm) ||
               Application.get_env(:comma_core, :salix_vm) do
          config when is_map(config) and map_size(config) > 0 -> {:ok, stringify(config)}
          _ -> {:error, :platform_vm_not_configured}
        end
    end
  end

  defp check_default_provider(%{"default_provider" => "cloudflare"}), do: :ok

  defp check_default_provider(config),
    do: {:error, {:default_provider, config["default_provider"]}}

  defp cloudflare_section(config) do
    case get_in(config, ["providers", "cloudflare"]) do
      %{"enabled" => true} = section ->
        base_url = section["gateway_base_url"] || section["base_url"]
        secret = section["gateway_secret"] || section["secret"]

        cond do
          blank?(base_url) -> {:error, :cloudflare_gateway_base_url_missing}
          blank?(secret) -> {:error, :cloudflare_gateway_secret_missing}
          true -> {:ok, Map.merge(section, %{"base_url" => base_url, "secret" => secret})}
        end

      _ ->
        {:error, :cloudflare_provider_not_enabled}
    end
  end

  defp check_health(section) do
    url = String.trim_trailing(section["base_url"], "/") <> "/healthz"

    case Req.get(url: url, receive_timeout: 10_000) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {:healthz_status, status, body}}
      {:error, reason} -> {:error, {:healthz_failed, reason}}
    end
  end

  defp maybe_probe_sandbox(_section, opts) do
    case Keyword.get(opts, :sandbox_id) do
      nil -> :ok
      "" -> :ok
      sandbox_id -> probe_sandbox(sandbox_id, opts)
    end
  end

  defp probe_sandbox(sandbox_id, opts) do
    operation_id =
      "preflight-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

    with {:ok, config} <- platform_config(),
         {:ok, section} <- cloudflare_section(config),
         client <- cloudflare_client(section),
         {:ok, ^operation_id} <-
           SalixStore.Compute.begin_cloudflare_direct_gateway_attempt(operation_id) do
      result =
        with :ok <- check_probe_status(client, sandbox_id),
             {:ok, _} <- Client.ensure(client, sandbox_id, keep_alive: false),
             :ok <- maybe_destroy_probe_sandbox(client, sandbox_id, opts) do
          :ok
        end

      cond do
        result == :ok and Keyword.get(opts, :keep, false) ->
          Mix.shell().info("Kept Sandbox requires release reconciliation: #{operation_id}")
          :ok

        result == :ok ->
          SalixStore.Compute.finish_cloudflare_direct_gateway_attempt(operation_id)

        true ->
          result
      end
    end
    |> case do
      :ok -> :ok
      {:error, reason} -> {:error, {:sandbox_probe_failed, reason}}
    end
  end

  defp cloudflare_client(section) do
    Client.new(
      base_url: section["base_url"],
      secret: section["secret"],
      worker_name: section["worker_name"],
      max_retries: 0
    )
  end

  defp check_probe_status(client, sandbox_id) do
    case Client.status(client, sandbox_id) do
      {:ok, _status} -> :ok
      {:error, {:api_error, 404, _body}} -> :ok
      {:error, reason} -> {:error, {:status_failed, reason}}
    end
  end

  defp maybe_destroy_probe_sandbox(client, sandbox_id, opts) do
    if Keyword.get(opts, :keep, false) do
      :ok
    else
      case Client.destroy(client, sandbox_id) do
        :ok -> :ok
        {:error, reason} -> {:error, {:destroy_failed, reason}}
      end
    end
  end

  defp stringify(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify_value(value)} end)

  defp stringify_value(value) when is_map(value), do: stringify(value)
  defp stringify_value(value), do: value

  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""
  defp format_reason(reason), do: inspect(reason)
end
