defmodule SalixWeb.CloudVM do
  @moduledoc "Group and tenant cloud-provider settings. Compute owns resource lifecycle."
  alias SalixStore.{Crypto, Keys, S3}
  @cloudflare_worker_name "salix-vm-verify"
  @config_missing_error "vm.enabled requires tenant vm provider configuration"
  @empty_organization_vm %{
    "config_source" => "organization",
    "default_provider" => "cloudflare",
    "providers" => %{}
  }

  # ---- tenant config ----

  @doc """
  The deployment-wide platform cloud-VM configuration
  (`ctl/vm/default_config.json`): the same shape as a tenant's `vm` section
  (`default_provider`, `providers.cloudflare`), managed
  from the Salix dashboard / `/v1/admin/vm/default-config`.

  Tenants use this when their tenant config explicitly opts in with
  `"vm.config_source" == "platform"`, and as the fallback for tenants that
  have no VM config of their own.
  """
  @spec default_vm_config() :: {:ok, map()} | {:error, :not_configured}
  def default_vm_config do
    case S3.get(Keys.ctl_vm_default_config()) do
      {:ok, %{body: body}} ->
        case Jason.decode(body) do
          {:ok, %{} = config} -> {:ok, config}
          _ -> {:error, :not_configured}
        end

      {:error, :not_found} ->
        {:error, :not_configured}

      {:error, _reason} ->
        {:error, :not_configured}
    end
  end

  @doc """
  Create/replace the deployment default cloud-VM configuration. Validates the
  same invariants agent provisioning relies on; secrets follow the write-only
  convention (`redacted_default_vm_config/0` for reads back to UIs). Blank
  secret fields keep the currently stored value (pointer-merge, like the
  OAuth apps).
  """
  @spec put_default_vm_config(map()) :: {:ok, map()} | {:error, term()}
  def put_default_vm_config(attrs) when is_map(attrs) do
    current =
      case default_vm_config() do
        {:ok, config} -> config
        _ -> %{}
      end

    merged = merge_default_vm_config(current, attrs)

    with :ok <- reject_retired_provider(attrs),
         :ok <- validate_default_vm_config(merged) do
      case S3.put(Keys.ctl_vm_default_config(), Jason.encode!(merged)) do
        {:ok, _} -> {:ok, redact_vm_config(merged)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def put_default_vm_config(_attrs), do: {:error, {:bad_request, "config must be a JSON object"}}

  @doc "Remove the deployment default cloud-VM configuration."
  @spec delete_default_vm_config() :: :ok | {:error, term()}
  def delete_default_vm_config do
    case S3.delete(Keys.ctl_vm_default_config()) do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Deployment-owned desired Cloudflare Worker release fact."
  @spec worker_release() :: map()
  def worker_release do
    case S3.get(Keys.ctl_vm_worker_release()) do
      {:ok, %{body: body}} -> Jason.decode!(body)
      {:error, _} -> %{}
    end
  end

  @doc "Set the desired Cloudflare Worker version used by new and switched VMs."
  @spec put_worker_release(map()) :: {:ok, map()} | {:error, term()}
  def put_worker_release(attrs) when is_map(attrs) do
    with {:ok, release} <- normalize_worker_release(attrs),
         {:ok, _} <- S3.put(Keys.ctl_vm_worker_release(), Jason.encode!(release)) do
      {:ok, release}
    end
  end

  def put_worker_release(_attrs),
    do: {:error, {:bad_request, "worker release must be a JSON object"}}

  defp normalize_worker_release(attrs) do
    version =
      blank_to_nil_str(attrs["desired_worker_version_id"] || attrs[:desired_worker_version_id])

    if is_nil(version) do
      {:error, {:bad_request, "desired_worker_version_id is required"}}
    else
      release_id =
        blank_to_nil_str(attrs["worker_release_id"] || attrs[:worker_release_id]) ||
          "worker-release-" <> (Crypto.hex(version) |> binary_part(0, 16))

      with {:ok, kind} <-
             release_kind(attrs["worker_release_kind"] || attrs[:worker_release_kind]) do
        previous_release = worker_release()
        previous_image_revision = previous_release["last_sandbox_image_revision"]
        previous_image_digest = previous_release["last_sandbox_image_digest"]

        supplied_image_revision =
          blank_to_nil_str(
            attrs["last_sandbox_image_revision"] || attrs[:last_sandbox_image_revision]
          )

        supplied_image_digest =
          blank_to_nil_str(
            attrs["last_sandbox_image_digest"] || attrs[:last_sandbox_image_digest]
          )

        image_revision = supplied_image_revision || previous_image_revision
        image_digest = supplied_image_digest || previous_image_digest

        cond do
          is_nil(supplied_image_revision) != is_nil(supplied_image_digest) ->
            {:error, {:bad_request, "image revision and digest must be set together"}}

          image_revision != nil and
              (not is_binary(image_revision) or
                 not Regex.match?(~r/\A[0-9a-f]{40}\z/, image_revision)) ->
            {:error, {:bad_request, "last_sandbox_image_revision must be a 40-character SHA"}}

          image_digest != nil and
              (not is_binary(image_digest) or
                 not Regex.match?(~r/\Asha256:[0-9a-f]{64}\z/, image_digest)) ->
            {:error, {:bad_request, "last_sandbox_image_digest must be a SHA-256 digest"}}

          true ->
            {:ok,
             %{
               "desired_worker_version_id" => version,
               "worker_release_id" => release_id,
               "worker_release_kind" => kind,
               "last_sandbox_image_revision" => image_revision,
               "last_sandbox_image_digest" => image_digest,
               "updated_at" => now_ms()
             }}
        end
      end
    end
  end

  def release_kind(nil), do: {:ok, "gateway_only"}
  def release_kind(""), do: {:ok, "gateway_only"}

  def release_kind(kind)
      when kind in ["gateway_only", "breaking_connector", "breaking_protocol", "sandbox_image"],
      do: {:ok, kind}

  def release_kind(kind), do: {:error, {:bad_request, "unknown worker_release_kind: #{kind}"}}

  @doc "The default VM config with secret fields replaced by configured-flags."
  @spec redacted_default_vm_config() :: map()
  def redacted_default_vm_config do
    case default_vm_config() do
      {:ok, config} -> redact_vm_config(config)
      _ -> %{}
    end
  end

  @spec default_provider(String.t()) :: {:ok, String.t()} | {:error, term()}
  def default_provider(tenant_id) do
    with {:ok, config} <- tenant_vm_config(tenant_id) do
      provider = config["default_provider"] || "cloudflare"

      if provider == "cloudflare" do
        {:ok, provider}
      else
        {:error, {:bad_request, "vm.default_provider must be cloudflare"}}
      end
    end
  end

  @doc """
  Validate that VM may be enabled for `tenant_id`.
  """
  @spec validate_enabled(String.t(), String.t()) :: :ok | {:error, {:bad_request, String.t()}}
  def validate_enabled(_tenant_id, "sprites"),
    do:
      {:error,
       {:bad_request,
        "Sprites is retired. Migrate its files, archives, and bindings to Cloudflare before enabling cloud compute."}}

  def validate_enabled(tenant_id, "cloudflare") do
    with {:ok, config} <- tenant_vm_config(tenant_id),
         %{"enabled" => true} <- get_in(config, ["providers", "cloudflare"]) do
      :ok
    else
      _ -> {:error, {:bad_request, @config_missing_error <> ": cloudflare"}}
    end
  end

  def validate_enabled(_tenant_id, _provider),
    do: {:error, {:bad_request, "vm.provider must be cloudflare"}}

  @spec validate_group_provider(String.t(), String.t()) :: :ok | {:error, term()}
  def validate_group_provider(group_id, provider) do
    case SalixStore.Compute.group_workload(group_id) do
      {:ok, %{"provider" => ^provider}} ->
        :ok

      {:ok, _} ->
        {:error, {:conflict, "vm provider change requires a data-preserving Compute handoff"}}

      {:error, :not_found} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The tenant's effective VM config. Tenants that wrote any VM config own it
  # (or opt in to platform config through config_source); tenants that never
  # configured VM fall back to the deployment platform config.
  defp tenant_vm_config(tenant_id) do
    with {:ok, config} <- tenant_json_config(tenant_id),
         {:ok, vm_config} <- effective_vm_config(config) do
      {:ok, vm_config}
    end
  end

  defp tenant_json_config(tenant_id) do
    with {:ok, %{body: body}} <- S3.get(Keys.ctl_tenant(tenant_id)),
         {:ok, tenant} <- Jason.decode(body),
         {:ok, config} <- decode_config(tenant["config"]) do
      {:ok, config}
    else
      {:error, :not_found} -> {:error, :not_configured}
      {:error, reason} -> {:error, reason}
    end
  end

  defp effective_vm_config(config) when is_map(config) do
    vm_config = organization_vm_config(config)

    case vm_config_source(vm_config) do
      {:ok, "platform"} ->
        platform_vm_config()

      {:ok, "organization"} ->
        with true <- unconfigured_vm?(config),
             {:ok, platform} <- platform_vm_config() do
          {:ok, platform}
        else
          # Tenant-owned config, or no platform config to fall back to: the
          # organization config stands (and surfaces not-configured itself).
          _ -> {:ok, vm_config}
        end

      {:error, _} = err ->
        err
    end
  end

  # A tenant that never touched VM config inherits the platform config. Writing
  # anything under `vm` pins the tenant to organization-owned config.
  defp unconfigured_vm?(config) do
    vm_empty? =
      case config["vm"] do
        section when is_map(section) -> map_size(section) == 0
        _ -> true
      end

    vm_empty?
  end

  defp organization_vm_config(config) do
    vm =
      case config["vm"] do
        section when is_map(section) -> stringify_config(section)
        _ -> @empty_organization_vm
      end

    normalize_vm_config(vm)
  end

  defp platform_vm_config do
    config =
      case default_vm_config() do
        {:ok, vm} ->
          vm

        _ ->
          Application.get_env(:salix_web, :platform_vm) ||
            Application.get_env(:comma_core, :salix_vm)
      end

    case config do
      section when is_map(section) and map_size(section) > 0 ->
        {:ok, section |> normalize_vm_config() |> Map.put("config_source", "platform")}

      section when is_list(section) and section != [] ->
        {:ok,
         section |> Map.new() |> normalize_vm_config() |> Map.put("config_source", "platform")}

      _ ->
        {:error, :not_configured}
    end
  end

  defp normalize_vm_config(config) when is_map(config) do
    config = stringify_config(config)

    providers =
      case config["providers"] do
        providers when is_map(providers) -> stringify_config(providers)
        _ -> %{}
      end

    config
    |> Map.put_new("config_source", "organization")
    |> Map.put_new("default_provider", "cloudflare")
    |> Map.put("providers", providers)
  end

  defp vm_config_source(%{"config_source" => source})
       when source in ["platform", "organization"],
       do: {:ok, source}

  defp vm_config_source(%{"config_source" => source}) when is_binary(source),
    do: {:error, {:bad_request, "vm.config_source must be platform or organization"}}

  defp vm_config_source(%{"follow_platform" => true}), do: {:ok, "platform"}
  defp vm_config_source(%{"follow_platform" => false}), do: {:ok, "organization"}
  defp vm_config_source(_vm_config), do: {:ok, "organization"}

  defp stringify_config(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), stringify_config(nested)} end)
  end

  defp stringify_config(values) when is_list(values), do: Enum.map(values, &stringify_config/1)
  defp stringify_config(value), do: value

  defp as_map(value) when is_map(value), do: value
  defp as_map(_value), do: %{}

  # Pointer-merge for the default config: blank/absent secret fields keep the
  # stored value; everything else in the incoming attrs wins.
  defp merge_default_vm_config(current, attrs) do
    current_providers = as_map(current["providers"])
    incoming_providers = as_map(attrs["providers"])

    providers =
      Map.merge(current_providers, incoming_providers, fn _provider, stored, incoming ->
        keep_stored_secrets(as_map(stored), as_map(incoming))
      end)

    %{
      "default_provider" =>
        blank_to_nil_str(attrs["default_provider"]) || current["default_provider"],
      "providers" => providers
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp reject_retired_provider(%{"providers" => %{"sprites" => _}}),
    do: {:error, {:bad_request, "Sprites is retired"}}

  defp reject_retired_provider(_attrs), do: :ok

  @vm_secret_fields ~w(token secret gateway_secret)

  defp keep_stored_secrets(stored, incoming) do
    Enum.reduce(@vm_secret_fields, incoming, fn field, acc ->
      case blank_to_nil_str(acc[field]) do
        nil ->
          case stored[field] do
            nil -> Map.delete(acc, field)
            kept -> Map.put(acc, field, kept)
          end

        _present ->
          acc
      end
    end)
  end

  defp redact_vm_config(config) do
    providers =
      config
      |> as_map()
      |> Map.get("providers", %{})
      |> as_map()
      |> Map.new(fn {provider, section} ->
        section = as_map(section)

        redacted =
          Enum.reduce(@vm_secret_fields, section, fn field, acc ->
            case blank_to_nil_str(acc[field]) do
              nil -> Map.delete(acc, field)
              _present -> acc |> Map.delete(field) |> Map.put(field <> "_configured", true)
            end
          end)

        {provider, redacted}
      end)

    config
    |> as_map()
    |> Map.take(["default_provider"])
    |> Map.put("providers", providers)
  end

  defp validate_default_vm_config(config) do
    provider = config["default_provider"]
    providers = as_map(config["providers"])

    cond do
      not (is_nil(provider) or provider == "cloudflare") ->
        {:error, {:bad_request, "vm.default_provider must be cloudflare"}}

      not Enum.all?(Map.values(providers), &is_map/1) ->
        {:error, {:bad_request, "vm.providers sections must be JSON objects"}}

      true ->
        :ok
    end
  end

  defp blank_to_nil_str(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil_str(_value), do: nil

  def cloudflare_config(tenant_id) do
    with {:ok, config} <- tenant_vm_config(tenant_id) do
      case get_in(config, ["providers", "cloudflare"]) do
        %{"enabled" => true} = section ->
          base_url = section["gateway_base_url"] || section["base_url"]
          secret = section["gateway_secret"] || section["secret"]

          if is_binary(base_url) and base_url != "" and is_binary(secret) and secret != "" do
            {:ok,
             %{
               base_url: String.trim_trailing(base_url, "/"),
               secret: secret,
               worker_name: section["worker_name"] || @cloudflare_worker_name
             }}
          else
            {:error, :not_configured}
          end

        _ ->
          {:error, :not_configured}
      end
    end
  end

  defp decode_config(nil), do: {:ok, %{}}
  defp decode_config(""), do: {:ok, %{}}
  defp decode_config(config) when is_map(config), do: {:ok, config}

  defp decode_config(config) when is_binary(config) do
    case Jason.decode(config) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      _ -> {:ok, %{}}
    end
  end

  defp now_ms, do: System.system_time(:millisecond)
end
