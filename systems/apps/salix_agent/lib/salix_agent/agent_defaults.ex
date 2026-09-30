defmodule SalixAgent.AgentDefaults do
  @moduledoc """
  Platform model defaults and tenant creation defaults for Routers and Workers.

  An Agent with a template_id uses that template. An Agent without one follows
  the platform role default. Tenant defaults are copied only at creation.
  An unset platform role uses the standalone default template (gpt-test).

  Storage:

    * platform: `ctl/system/agent_defaults.json`, global templates only.
    * tenant: the `agent_defaults` section of the tenant record config
      (`Salix.Control.Tenants.update_config/3`), global or own-tenant templates.
  """

  alias SalixAgent.Templates
  alias SalixStore.{Keys, S3}

  @roles ~w(router worker)
  @fields %{"router" => "router_template_id", "worker" => "worker_template_id"}
  @field_names Map.values(@fields)

  @type source :: :pinned | :tenant_default | :platform_default

  def roles, do: @roles
  def field(role) when role in @roles, do: Map.fetch!(@fields, role)
  def fields, do: @field_names

  @doc "Resolve the effective template id and its source for an Agent record."
  @spec resolve_template_id(map()) ::
          {:ok, String.t(), source()} | {:error, :agent_template_unresolved | term()}
  def resolve_template_id(rec) when is_map(rec) do
    case blank_to_nil(rec["template_id"]) do
      nil -> resolve_platform_default(rec["role"])
      template_id -> {:ok, template_id, :pinned}
    end
  end

  @doc "Resolve the effective template record and its source for an Agent record."
  @spec resolve_template(map()) :: {:ok, map(), source()} | {:error, term()}
  def resolve_template(rec) when is_map(rec) do
    with {:ok, template_id, source} <- resolve_template_id(rec),
         {:ok, template} <- Templates.get(template_id, rec["tenant_id"]) do
      {:ok, template, source}
    else
      {:error, :not_found} -> {:error, :agent_template_unresolved}
      error -> error
    end
  end

  @doc "The default template id for a role in a tenant: tenant layer, then platform."
  @spec resolve_role_default(String.t() | nil, String.t() | nil) ::
          {:ok, String.t(), :tenant_default | :platform_default}
          | {:error, :agent_template_unresolved | term()}
  def resolve_role_default(role, tenant_id) when role in @roles do
    field = field(role)

    with {:ok, tenant_defaults} <- tenant(tenant_id) do
      case blank_to_nil(tenant_defaults[field]) do
        nil ->
          resolve_platform_default(role)

        id ->
          {:ok, id, :tenant_default}
      end
    end
  end

  # Meeting and other non-product roles have no role default.
  def resolve_role_default(_role, _tenant_id), do: {:error, :agent_template_unresolved}

  @doc "The template choice copied to a new Agent; nil keeps platform following."
  def creation_template(role, tenant_id) when role in @roles do
    with {:ok, defaults} <- tenant(tenant_id), do: {:ok, blank_to_nil(defaults[field(role)])}
  end

  def creation_template(_role, _tenant_id), do: {:ok, nil}

  def resolve_platform_default(role) when role in @roles do
    with {:ok, defaults} <- platform() do
      case blank_to_nil(defaults[field(role)]) do
        nil ->
          with {:ok, template} <- ensure_fallback_template(),
               do: {:ok, template["template_id"], :platform_default}

        id ->
          {:ok, id, :platform_default}
      end
    end
  end

  def resolve_platform_default(_role), do: {:error, :agent_template_unresolved}

  defp ensure_fallback_template do
    case Templates.get("default") do
      {:error, :not_found} ->
        case Templates.create(%{
               "template_id" => "default",
               "name" => "Default",
               "model" => "gpt-test"
             }) do
          {:error, :exists} -> Templates.get("default")
          result -> result
        end

      result ->
        result
    end
  end

  @doc "Concrete choices omit the built-in fallback, which is represented by Default."
  def selectable(templates), do: Enum.reject(templates, &(&1["template_id"] == "default"))

  def default_label(role) do
    with {:ok, id, _} <- resolve_platform_default(role),
         {:ok, template} <- Templates.get(id) do
      "Default (#{SalixAgent.ModelPresentation.name(template)})"
    else
      _ -> "Default (unavailable)"
    end
  end

  def default_icon(role) do
    with {:ok, id, _} <- resolve_platform_default(role),
         {:ok, template} <- Templates.get_public(id) do
      template["model_icon"]
    else
      _ -> nil
    end
  end

  @doc "Platform default pointers. A missing object is an empty configuration."
  @spec platform() :: {:ok, map()} | {:error, term()}
  def platform do
    SalixStore.ReadScope.fetch({:platform_agent_defaults}, fn ->
      case S3.get(Keys.ctl_system_agent_defaults()) do
        {:ok, %{body: body}} ->
          case Jason.decode(body) do
            {:ok, map} when is_map(map) -> {:ok, Map.take(map, @field_names)}
            _ -> {:error, :platform_agent_defaults_invalid}
          end

        {:error, :not_found} ->
          {:ok, %{}}

        {:error, _} = error ->
          error
      end
    end)
  end

  @doc """
  Update platform default pointers. Each present field is validated: `nil` or
  `""` clears the pointer; any other value must name a visible global template.
  """
  @spec update_platform(map()) :: {:ok, map()} | {:error, term()}
  def update_platform(attrs) when is_map(attrs) do
    with {:ok, changes} <- validate_attrs(attrs, nil),
         {:ok, current, etag} <- read_platform_for_update() do
      next = current |> Map.merge(changes) |> Enum.reject(&is_nil(elem(&1, 1))) |> Map.new()
      body = Jason.encode!(next)

      put_result =
        if etag,
          do: S3.put(Keys.ctl_system_agent_defaults(), body, if_match: etag),
          else: S3.put(Keys.ctl_system_agent_defaults(), body, if_none_match: "*")

      case put_result do
        {:ok, _} -> {:ok, next}
        {:error, :precondition_failed} -> {:error, :conflict}
        {:error, _} = error -> error
      end
    end
  end

  @doc "Tenant default pointers from the tenant record's `agent_defaults` section."
  @spec tenant(String.t() | nil) :: {:ok, map()} | {:error, term()}
  def tenant(tenant_id) when is_binary(tenant_id) and tenant_id != "" do
    SalixStore.ReadScope.fetch({:tenant_agent_defaults, tenant_id}, fn ->
      case S3.get(Keys.ctl_tenant(tenant_id)) do
        {:ok, %{body: body}} ->
          with {:ok, rec} <- Jason.decode(body),
               {:ok, config} <- decode_config(rec["config"]) do
            section = Map.get(config, "agent_defaults", %{})
            {:ok, if(is_map(section), do: Map.take(section, @field_names), else: %{})}
          else
            _ -> {:error, :tenant_agent_defaults_invalid}
          end

        {:error, :not_found} ->
          {:ok, %{}}

        {:error, _} = error ->
          error
      end
    end)
  end

  def tenant(_tenant_id), do: {:ok, %{}}

  @doc """
  Validate default pointer attributes for a tenant (or the platform when
  `tenant_id` is `nil`). Unknown keys pass through untouched so callers that
  merge other `agent_defaults` settings keep working.
  """
  @spec validate_attrs(map(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def validate_attrs(attrs, tenant_id) when is_map(attrs) do
    Enum.reduce_while(attrs, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      cond do
        key not in @field_names ->
          {:cont, {:ok, Map.put(acc, key, value)}}

        value in [nil, ""] ->
          {:cont, {:ok, Map.put(acc, key, nil)}}

        not is_binary(value) ->
          {:halt, {:error, {:bad_request, "#{key} must be a template id"}}}

        is_nil(tenant_id) and SalixStore.Ids.valid_private_template_id?(value) ->
          {:halt, {:error, {:bad_request, "platform defaults must be global templates"}}}

        true ->
          case Templates.get(value, tenant_id) do
            {:ok, %{"hidden" => true}} ->
              {:halt, {:error, {:bad_request, "#{key} template not found"}}}

            {:ok, _} ->
              {:cont, {:ok, Map.put(acc, key, value)}}

            {:error, :not_found} ->
              {:halt, {:error, {:bad_request, "#{key} template not found"}}}

            {:error, _} = error ->
              {:halt, error}
          end
      end
    end)
  end

  @doc """
  Whether the platform or the given tenant's defaults point at `template_id`.

  A storage or decode failure is returned as an error so delete protection
  can fail closed. A missing object is an empty configuration.
  """
  @spec referenced?(String.t(), String.t() | nil) :: {:ok, boolean()} | {:error, term()}
  def referenced?(template_id, tenant_id) do
    with {:ok, platform_defaults} <- platform(),
         {:ok, tenant_defaults} <- tenant(tenant_id) do
      {:ok, template_id in (Map.values(platform_defaults) ++ Map.values(tenant_defaults))}
    end
  end

  @doc """
  Tenants whose defaults point at a global template. Reads every tenant record
  and is reserved for the operator-only global template deletion path.

  A tenant record that cannot be read fails the whole check. The caller must
  not treat an unread tenant as "not referencing".
  """
  @spec tenants_referencing(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def tenants_referencing(template_id) do
    with {:ok, objects} <- S3.list_all(Keys.ctl_tenants_prefix(), delimiter: "/", max_keys: 100) do
      objects
      |> Enum.map(fn %{key: key} -> key |> Path.basename() |> String.trim_trailing(".json") end)
      |> Enum.reduce_while({:ok, []}, fn tenant_id, {:ok, acc} ->
        case tenant(tenant_id) do
          {:ok, defaults} ->
            if template_id in Map.values(defaults),
              do: {:cont, {:ok, [tenant_id | acc]}},
              else: {:cont, {:ok, acc}}

          {:error, _} = error ->
            {:halt, error}
        end
      end)
      |> case do
        {:ok, ids} -> {:ok, Enum.reverse(ids)}
        {:error, _} = error -> error
      end
    end
  end

  @doc "Public JSON for a default pointer set, with the resolved template names."
  @spec public_json(map(), String.t() | nil) :: map()
  def public_json(defaults, tenant_id) do
    Map.new(@roles, fn role ->
      {role, describe_pointer(blank_to_nil(defaults[field(role)]), tenant_id)}
    end)
  end

  @doc """
  The effective default per role for a tenant after layering, each with its
  `source`, or `nil` when no layer resolves. This describes the initial model for a newly created Agent.
  """
  @spec effective_role_defaults(String.t() | nil) :: map()
  def effective_role_defaults(tenant_id) do
    Map.new(@roles, fn role ->
      case resolve_role_default(role, tenant_id) do
        {:ok, template_id, source} ->
          {role,
           template_id
           |> describe_pointer(tenant_id)
           |> Map.put("source", Atom.to_string(source))}

        _ ->
          {role, nil}
      end
    end)
  end

  defp describe_pointer(nil, _tenant_id), do: nil

  defp describe_pointer(template_id, tenant_id) do
    case Templates.get_public(template_id, tenant_id) do
      {:ok, template} ->
        Map.take(
          template,
          ~w(template_id name model provider scope model_display_name model_vendor model_icon account_pool)
        )

      _ ->
        %{"template_id" => template_id}
    end
  end

  defp read_platform_for_update do
    case S3.get(Keys.ctl_system_agent_defaults()) do
      {:ok, %{body: body, etag: etag}} ->
        case Jason.decode(body) do
          {:ok, map} when is_map(map) -> {:ok, Map.take(map, @field_names), etag}
          _ -> {:ok, %{}, etag}
        end

      {:error, :not_found} ->
        {:ok, %{}, nil}

      {:error, _} = error ->
        error
    end
  end

  defp decode_config(nil), do: {:ok, %{}}
  defp decode_config(""), do: {:ok, %{}}
  defp decode_config(config) when is_map(config), do: {:ok, config}

  defp decode_config(config) when is_binary(config) do
    case Jason.decode(config) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, _} -> {:ok, %{}}
      {:error, _} = error -> error
    end
  end

  defp decode_config(_), do: {:ok, %{}}

  defp blank_to_nil(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp blank_to_nil(_), do: nil
end
