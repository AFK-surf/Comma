defmodule SalixAgent.Templates do
  @moduledoc """
  Agent template public API.
  """

  alias SalixAgent.Control
  alias SalixAgent.LLMProvider
  alias SalixStore.{Ids, Keys, S3}

  @list_read_concurrency 8

  def list do
    Keys.ctl_templates_prefix()
    |> list_records()
    |> Enum.reject(&(&1["hidden"] == true))
    |> Enum.map(&public_json/1)
  end

  def list_admin do
    Keys.ctl_templates_prefix()
    |> list_records()
    |> Enum.map(&admin_json/1)
  end

  @doc "One global management page, including hidden templates."
  def list_admin_page(cursor \\ nil) do
    with {:ok, %{objects: objects, next: next}} <-
           S3.list(Keys.ctl_templates_prefix(), max_keys: 50, continuation_token: cursor),
         {:ok, records} <- read_bounded_records(objects) do
      {:ok, %{templates: Enum.map(records, &admin_json/1), next_cursor: next}}
    end
  end

  @doc """
  Read a bounded, credential-free Template catalog.

  Interactive control surfaces must not turn one request into an unbounded
  object-store scan. The call therefore rejects catalogs larger than `limit`
  before reading Template objects and surfaces storage failures instead of
  folding them into an empty catalog.
  """
  @spec list_public_bounded(pos_integer()) :: {:ok, [map()]} | {:error, term()}
  def list_public_bounded(limit) when is_integer(limit) and limit > 0 and limit <= 100 do
    with {:ok, %{objects: objects, next: next}} <-
           S3.list(Keys.ctl_templates_prefix(), max_keys: limit + 1),
         :ok <- ensure_catalog_bound(objects, next, limit),
         {:ok, records} <- read_bounded_records(objects) do
      {:ok,
       records
       |> Enum.reject(&(&1["hidden"] == true))
       |> Enum.map(&public_json/1)}
    end
  end

  def list_public_bounded(_limit), do: {:error, :invalid_model_catalog_limit}

  # A tenant context permits global reads as well as reads of its own private templates.
  # Context-free APIs remain global-only, including operator template-name references.
  @doc "Visible global and own-tenant templates; credentials are never included."
  def list_available(tenant_id, limit \\ 100) do
    with {:ok, global} <- list_public_bounded(limit),
         {:ok, private} <- list_private(tenant_id, limit),
         visible = private |> Enum.reject(&(&1["hidden"] == true)) |> Enum.map(&public_json/1),
         :ok <- ensure_catalog_bound(global ++ visible, nil, limit) do
      {:ok, global ++ visible}
    end
  end

  @doc "Bounded management view of one tenant's private templates."
  def list_private(tenant_id, limit \\ 100) do
    with :ok <- validate_tenant(tenant_id),
         true <- is_integer(limit) and limit > 0 and limit <= 100,
         {:ok, %{objects: objects, next: next}} <-
           S3.list(Keys.ctl_private_templates_prefix(tenant_id), max_keys: limit + 1),
         :ok <- ensure_catalog_bound(objects, next, limit),
         {:ok, records} <- read_bounded_records(objects) do
      if Enum.all?(records, &(validate_owner(&1, &1["template_id"], tenant_id) == :ok)) do
        {:ok, Enum.map(records, &admin_json/1)}
      else
        {:error, :invalid_template_owner}
      end
    else
      false -> {:error, :invalid_model_catalog_limit}
      error -> error
    end
  end

  defp template_key("ptm1_" <> _ = id, tenant_id) do
    with :ok <- require_private(id, tenant_id) do
      {:ok, Keys.ctl_private_template(tenant_id, id)}
    end
  end

  defp template_key(id, _tenant_id) when is_binary(id) and id != "",
    do: {:ok, Keys.ctl_template(id)}

  defp template_key(_, _), do: {:error, :not_found}

  defp require_private(id, tenant_id) do
    if Ids.valid_private_template_id?(id) and Ids.valid_tenant_id?(tenant_id),
      do: :ok,
      else: {:error, :not_found}
  end

  defp validate_tenant(tenant_id) do
    if Ids.valid_tenant_id?(tenant_id),
      do: :ok,
      else: {:error, {:bad_request, "valid tenant_id is required"}}
  end

  # The request's authenticated tenant is the independent owner authority.
  # A wrong-tenant exact lookup fails closed before any provider config is returned.
  defp validate_owner(rec, id, tenant_id) do
    expected = if Ids.valid_private_template_id?(id), do: tenant_id, else: nil

    if rec["template_id"] == id and rec["tenant_id"] == expected,
      do: :ok,
      else: {:error, :not_found}
  end

  defp reject_owner_changes(attrs, id, tenant_id) do
    expected = %{
      "template_id" => id,
      "tenant_id" => tenant_id,
      "scope" => if(tenant_id, do: "tenant", else: "global")
    }

    if Enum.any?(expected, fn {key, value} -> Map.has_key?(attrs, key) and attrs[key] != value end),
       do: {:error, {:bad_request, "template identity and owner cannot be changed"}},
       else: :ok
  end

  def get(id, tenant_id \\ nil) do
    with {:ok, key} <- template_key(id, tenant_id),
         {:ok, rec} <- get_record(key),
         :ok <- validate_owner(rec, id, tenant_id),
         :ok <- validate_private_credentials(rec, rec["tenant_id"]) do
      {:ok, admin_json(rec)}
    end
  end

  @doc "Read one template's public, credential-free view."
  def get_public(id, tenant_id \\ nil) do
    with {:ok, rec} <- get(id, tenant_id) do
      {:ok, public_json(rec)}
    end
  end

  def create(attrs) when is_map(attrs), do: create_record(attrs, nil)

  def create_private(attrs, tenant_id) when is_map(attrs) do
    with :ok <- validate_tenant(tenant_id) do
      create_record(Map.put(attrs, "template_id", Ids.new_private_template_id()), tenant_id)
    end
  end

  @doc "Reuse a private subscription choice, or create it without changing existing templates."
  def resolve_private_subscription(attrs, tenant_id) do
    attrs = canonicalize_model(attrs)

    with :ok <- validate_tenant(tenant_id),
         pool when pool in ["codex", "claude"] <-
           get_in(attrs, ["provider_config", "account_pool"]) do
      # The database lock serializes menu resolutions across nodes. Its hash is
      # only a lock key, not template identity. Collisions only delay another tenant.
      SalixStore.Repo.transaction(
        fn ->
          with :ok <- lock_subscription_templates(tenant_id),
               {:ok, templates} <- list_private(tenant_id) do
            template =
              templates
              |> Enum.sort_by(& &1["template_id"])
              |> Enum.find(fn template ->
                template["hidden"] != true and template["model"] == attrs["model"] and
                  get_in(template, ["provider_config", "account_pool"]) == pool and
                  reasoning_effort(template) == reasoning_effort(attrs)
              end)

            if template do
              {:ok, template}
            else
              attrs =
                if pool == "codex",
                  do: Map.put_new(attrs, "image_config", codex_image_config()),
                  else: attrs

              with {:ok, available} <- list_available(tenant_id),
                   :ok <- ensure_catalog_bound(available, nil, 99) do
                create_private(attrs, tenant_id)
              end
            end
          end
        end,
        timeout: 30_000
      )
      |> case do
        {:ok, result} -> result
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_model_configuration}
    end
  end

  defp lock_subscription_templates(tenant_id) do
    with {:ok, _} <- SalixStore.Repo.query("SET LOCAL lock_timeout = '5s'", []),
         {:ok, _} <-
           SalixStore.Repo.query(
             "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
             ["subscription-template:" <> tenant_id]
           ) do
      :ok
    else
      _ -> {:error, :unavailable}
    end
  end

  # Match the provider's precedence when an existing template uses the native
  # Responses reasoning object instead of the generic effort field.
  defp reasoning_effort(template) do
    case template["provider_config"] || %{} do
      %{"reasoning" => reasoning} when is_map(reasoning) -> reasoning["effort"]
      config -> config["reasoning_effort"]
    end
  end

  defp create_record(attrs, tenant_id) do
    attrs = canonicalize_model(attrs)
    now = now()
    id = attrs["template_id"] || "tmpl-" <> random_id()

    with {:ok, key} <- template_key(id, tenant_id),
         :ok <- validate_create(attrs),
         :ok <- SalixAgent.ModelPresentation.validate(attrs),
         :ok <- validate_private_credentials(attrs, tenant_id),
         :ok <- validate_config_objects(attrs) do
      rec =
        %{
          "template_id" => id,
          "name" => attrs["name"],
          "model" => attrs["model"],
          "model_display_name" => attrs["model_display_name"],
          "model_vendor" => attrs["model_vendor"],
          "provider" => provider_from_attrs(attrs),
          "provider_config" => attrs["provider_config"] || %{},
          "request_headers" => attrs["request_headers"] || %{},
          "image_config" => attrs["image_config"] || %{},
          "video_config" => attrs["video_config"] || %{},
          "vision_describer_config" => attrs["vision_describer_config"] || %{},
          "analyze_config" => attrs["analyze_config"] || %{},
          "max_tokens" => attrs["max_tokens"] || 65_536,
          "context_tokens" => attrs["context_tokens"] || 0,
          "created_at" => now
        }
        |> put_optional("tenant_id", tenant_id)
        |> put_optional("supports_images", attrs["supports_images"])
        |> put_optional("hidden", attrs["hidden"])
        |> put_optional("purpose", attrs["purpose"])

      case put_new(key, rec) do
        {:ok, rec} -> {:ok, admin_json(rec)}
        other -> other
      end
    end
  end

  def update(id, attrs) when is_map(attrs), do: update_record_for_scope(id, attrs, nil)

  def update_private(id, attrs, tenant_id) when is_map(attrs) or is_function(attrs, 1) do
    with :ok <- require_private(id, tenant_id) do
      update_record_for_scope(id, attrs, tenant_id)
    end
  end

  defp update_record_for_scope(id, attrs_or_update, tenant_id) do
    with {:ok, key} <- template_key(id, tenant_id),
         {:ok, %{body: body, etag: etag}} <- S3.get(key),
         {:ok, record} <- Jason.decode(body),
         :ok <- validate_owner(record, id, tenant_id),
         :ok <- validate_private_credentials(record, record["tenant_id"]),
         {:ok, attrs} <- update_attrs(attrs_or_update, record),
         attrs = canonicalize_model(attrs),
         :ok <- reject_owner_changes(attrs, id, tenant_id),
         :ok <- validate_private_credentials(attrs, tenant_id),
         :ok <- validate_config_objects(attrs),
         attrs = SalixAgent.ModelPresentation.refresh(attrs, record),
         :ok <- SalixAgent.ModelPresentation.validate(attrs),
         updated = Map.merge(record, attrs),
         {:ok, _} <- S3.put(key, Jason.encode!(updated), if_match: etag) do
      {:ok, admin_json(updated)}
    end
  end

  defp update_attrs(fun, record) when is_function(fun, 1), do: fun.(record)
  defp update_attrs(attrs, _record), do: {:ok, attrs}

  def delete(id), do: delete_for_scope(id, nil)

  @doc "Delete a private template after a bounded reference read for product requests."
  def delete_private(id, tenant_id, limit)
      when is_integer(limit) and limit > 0 and limit <= 1000 do
    with :ok <- require_private(id, tenant_id),
         {:ok, _} <- get(id, tenant_id),
         :ok <- ensure_not_default(id, tenant_id),
         {:ok, %{objects: objects, next: next}} <-
           S3.list(Keys.ctl_agents_prefix_for_tenant(tenant_id), max_keys: limit + 1),
         :ok <- reference_bound(objects, next, limit),
         :ok <- check_agent_references(objects, id),
         {:ok, key} <- template_key(id, tenant_id) do
      S3.delete(key)
    end
  end

  defp reference_bound(objects, nil, limit) when length(objects) <= limit, do: :ok
  defp reference_bound(_, _, _), do: {:error, :template_reference_limit}

  defp check_agent_references(objects, id) do
    objects
    |> Task.async_stream(fn %{key: key} -> get_record(key) end,
      max_concurrency: 8,
      on_timeout: :kill_task
    )
    |> Enum.reduce_while(:ok, fn
      {:ok, {:ok, record}}, :ok ->
        if record["template_id"] == id and not Map.has_key?(record, "archived_at"),
          do: {:halt, {:error, {:conflict, "template is referenced by an agent"}}},
          else: {:cont, :ok}

      {:ok, {:error, :not_found}}, :ok ->
        {:cont, :ok}

      _, :ok ->
        {:halt, {:error, :template_reference_unavailable}}
    end)
  end

  def delete_private(id, tenant_id) do
    with :ok <- require_private(id, tenant_id) do
      delete_for_scope(id, tenant_id)
    end
  end

  defp delete_for_scope(id, tenant_id) do
    with {:ok, _template} <- get(id, tenant_id),
         :ok <- ensure_not_default(id, tenant_id),
         :ok <- ensure_unreferenced(id, tenant_id),
         {:ok, key} <- template_key(id, tenant_id) do
      S3.delete(key)
    end
  end

  # A template that a default pointer names is in use by every following
  # Agent, even though no Agent record references it directly.
  defp ensure_not_default(id, tenant_id) when is_binary(tenant_id) do
    case SalixAgent.AgentDefaults.referenced?(id, tenant_id) do
      {:ok, true} ->
        {:error,
         {:conflict,
          "This template is the default model. Change the default before deleting the template."}}

      {:ok, false} ->
        :ok

      {:error, _} ->
        {:error, :template_reference_unavailable}
    end
  end

  defp ensure_not_default(id, nil) do
    case SalixAgent.AgentDefaults.referenced?(id, nil) do
      {:ok, true} ->
        {:error, {:conflict, "template is the platform default"}}

      {:ok, false} ->
        case SalixAgent.AgentDefaults.tenants_referencing(id) do
          {:ok, []} ->
            :ok

          {:ok, tenants} ->
            {:error, {:conflict, "template is the default for #{length(tenants)} tenant(s)"}}

          {:error, _} ->
            {:error, :template_reference_unavailable}
        end

      {:error, _} ->
        {:error, :template_reference_unavailable}
    end
  end

  def snapshot(template_id, tenant_id \\ nil) do
    case get(template_id, tenant_id) do
      {:ok, template} -> template
      _ -> %{}
    end
  end

  @doc "Best-effort effective template for an Agent record; `%{}` when unresolved."
  def snapshot_for_record(rec) do
    case resolve_template_for_record(rec) do
      {:ok, template, _source} -> template
      _ -> %{}
    end
  end

  def name(id, tenant_id \\ nil) do
    with {:ok, template} <- get(id, tenant_id), do: template["name"]
  end

  def provider(id, tenant_id \\ nil) do
    with {:ok, template} <- get(id, tenant_id), do: template["provider"]
  end

  @doc """
  Resolve live provider config for an agent.

  Agent records pin a template by id or follow their role default
  (`SalixAgent.AgentDefaults`); template and default edits apply on the next
  activation. A missing agent record returns `{:ok, nil}`.
  """
  def resolve_llm_for_agent(agent_id) do
    case Control.get_record(agent_id) do
      {:ok, rec} -> resolve_llm_for_record(rec)
      {:error, :not_found} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  def resolve_media_for_agent(agent_id) do
    case Control.get_record(agent_id) do
      {:ok, rec} ->
        with {:ok, template_id, _source} <- resolve_template_id_for_record(rec) do
          resolve_media_for_template(template_id, rec["tenant_id"])
        end

      {:error, :not_found} ->
        {:ok, nil}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  The effective template for an Agent record and where it came from:
  `:pinned`, `:tenant_default`, or `:platform_default`.

  This is the only place that turns an Agent record into a template. Callers
  must not read `rec["template_id"]` and look the template up themselves,
  because a following Agent has no pin.
  """
  @spec resolve_template_for_record(map()) ::
          {:ok, map(), SalixAgent.AgentDefaults.source()} | {:error, term()}
  def resolve_template_for_record(rec), do: SalixAgent.AgentDefaults.resolve_template(rec)

  @doc "Public, credential-free view of an Agent record's effective template."
  @spec resolve_public_template_for_record(map()) ::
          {:ok, map(), SalixAgent.AgentDefaults.source()} | {:error, term()}
  def resolve_public_template_for_record(rec) do
    with {:ok, template, source} <- resolve_template_for_record(rec) do
      {:ok, public_json(template), source}
    end
  end

  @spec resolve_template_id_for_record(map()) ::
          {:ok, String.t(), SalixAgent.AgentDefaults.source()} | {:error, term()}
  def resolve_template_id_for_record(rec), do: SalixAgent.AgentDefaults.resolve_template_id(rec)

  def resolve_llm_for_record(rec) do
    case resolve_template_id_for_record(rec) do
      {:ok, template_id, _source} -> resolve_llm_for_template(template_id, rec["tenant_id"])
      {:error, :agent_template_unresolved} -> {:error, :agent_template_unresolved}
      {:error, reason} -> {:error, reason}
    end
  end

  def resolve_llm_for_template(template_id, tenant_id \\ nil)

  def resolve_llm_for_template(template_id, tenant_id)
      when is_binary(template_id) and template_id != "" do
    case llm_config_for_template(template_id, tenant_id) do
      {:ok, llm} -> {:ok, llm}
      {:error, :not_found} -> {:error, {:template_not_found, template_id}}
      {:error, reason} -> {:error, reason}
    end
  end

  def resolve_llm_for_template(_, _tenant_id), do: {:ok, nil}

  def resolve_llm_for_template_ref(ref) when is_binary(ref) and ref != "" do
    case resolve_llm_for_template(ref) do
      {:error, {:template_not_found, _}} ->
        case find_id_by_name(ref) do
          {:ok, id} -> resolve_llm_for_template(id)
          :error -> {:error, {:template_not_found, ref}}
        end

      other ->
        other
    end
  end

  def resolve_llm_for_template_ref(_), do: {:ok, nil}

  defp find_id_by_name(name) do
    case Enum.find(list_admin(), &(&1["name"] == name)) do
      %{"template_id" => id} when is_binary(id) and id != "" -> {:ok, id}
      _ -> :error
    end
  end

  def resolve_media_for_template(template_id, tenant_id \\ nil)

  def resolve_media_for_template(template_id, tenant_id)
      when is_binary(template_id) and template_id != "" do
    case get(template_id, tenant_id) do
      {:ok, tmpl} ->
        {:ok,
         %{
           "image_config" => image_scope(tmpl["image_config"], tmpl),
           "video_config" => media_scope(tmpl["video_config"], tmpl),
           "supports_images" => tmpl["supports_images"] == true,
           "vision_describer_config" => media_scope(tmpl["vision_describer_config"], tmpl),
           "analyze_config" => credential_scope(tmpl["analyze_config"] || %{}, tmpl)
         }}

      {:error, :not_found} ->
        {:error, {:template_not_found, template_id}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def resolve_media_for_template(_, _tenant_id), do: {:ok, nil}

  def public_json(rec) do
    %{
      "template_id" => rec["template_id"],
      "scope" => if(rec["tenant_id"], do: "tenant", else: "global"),
      "name" => rec["name"],
      "model" => rec["model"],
      "provider" => provider_for_template(rec),
      "max_tokens" => rec["max_tokens"] || 65_536,
      "context_tokens" => rec["context_tokens"] || 0,
      "reasoning_effort" => reasoning_effort(rec),
      "created_at" => rec["created_at"] || 0,
      "provider_type" => provider_type_from_config(rec["provider_config"])
    }
    |> Map.merge(SalixAgent.ModelPresentation.public(rec))
  end

  def admin_json(rec) do
    rec
    |> put_provider_default()
    |> Map.put_new("provider_config", %{})
    |> Map.put_new("request_headers", %{})
    |> Map.put_new("image_config", %{})
    |> Map.put_new("video_config", %{})
    |> Map.put_new("vision_describer_config", %{})
    |> Map.put_new("analyze_config", %{})
    |> Map.put_new("max_tokens", 65_536)
    |> Map.put_new("context_tokens", 0)
    |> Map.put("provider_type", provider_type_from_config(rec["provider_config"]))
  end

  def provider_type_from_config(%{"base_url" => base}) when is_binary(base) do
    LLMProvider.provider(%{"base_url" => base}) || "openai"
  end

  def provider_type_from_config(_config), do: "openai"

  def provider_from_config(config), do: LLMProvider.provider(config) || ""

  defp provider_from_attrs(attrs) do
    config = attrs["provider_config"] || %{}

    LLMProvider.normalize_provider(attrs["provider"]) ||
      LLMProvider.provider(Map.merge(config, %{"model" => attrs["model"]})) ||
      ""
  end

  defp provider_for_template(rec) do
    config = rec["provider_config"] || %{}

    LLMProvider.normalize_provider(rec["provider"]) ||
      LLMProvider.provider(Map.merge(config, %{"model" => rec["model"]})) ||
      ""
  end

  defp put_provider_default(rec) do
    provider = provider_for_template(rec)

    if provider == "" do
      rec
    else
      Map.put(rec, "provider", provider)
    end
  end

  defp llm_config_for_template(template_id, tenant_id) do
    with {:ok, tmpl} <- get(template_id, tenant_id) do
      model = LLMProvider.canonical_model(tmpl["model"])
      provider = provider_for_template(tmpl)

      pc =
        tmpl["provider_config"]
        |> Kernel.||(%{})
        |> default_openai_protocol(provider, model)

      headers = Map.merge(pc["default_headers"] || %{}, tmpl["request_headers"] || %{})

      llm =
        pc
        |> Map.put("model", model)
        |> Map.put("max_tokens", tmpl["max_tokens"])
        |> Map.put("provider", provider)
        |> Map.put("supports_images", tmpl["supports_images"] == true)

      llm = if headers == %{}, do: llm, else: Map.put(llm, "default_headers", headers)

      llm =
        case tmpl["context_tokens"] do
          n when is_integer(n) and n > 0 -> Map.put(llm, "context_tokens", n)
          _ -> llm
        end

      SalixAgent.AccountPool.resolve_config(credential_scope(llm, tmpl), tmpl["tenant_id"])
    end
  end

  defp credential_scope(config, _template) when map_size(config) == 0, do: config

  defp credential_scope(config, template) do
    Map.put(config, "credential_scope", if(template["tenant_id"], do: "tenant", else: "platform"))
  end

  # Private configuration is tenant authority, never authority to read node secrets.
  # Validate on admission and resolution so imported/stored unsafe records fail closed.
  defp validate_private_credentials(attrs, tenant_id) do
    with :ok <- SalixAgent.AccountPool.validate_config(attrs["provider_config"], tenant_id),
         :ok <- validate_image_pool(attrs["image_config"], tenant_id) do
      validate_server_credentials(attrs, tenant_id)
    end
  end

  defp validate_image_pool(%{"provider_config" => %{"account_pool" => pool}} = cfg, tenant) do
    if pool == "codex" and is_binary(tenant) and cfg["provider"] == "openai" and
         cfg["model"] == "gpt-image-2" do
      :ok
    else
      {:error,
       {:bad_request,
        "image account pools require a private template, openai, gpt-image-2 and codex"}}
    end
  end

  defp validate_image_pool(_, _), do: :ok

  defp image_scope(config, template) do
    config =
      if config in [nil, %{}] and is_binary(template["tenant_id"]) and
           get_in(template, ["provider_config", "account_pool"]) == "codex" do
        codex_image_config()
      else
        config
      end

    config = media_scope(config, template) |> Map.delete("account_pool_tenant")

    if match?(%{"provider_config" => %{"account_pool" => "codex"}}, config),
      do: Map.put(config, "account_pool_tenant", template["tenant_id"]),
      else: config
  end

  defp codex_image_config do
    %{
      "provider" => "openai",
      "model" => "gpt-image-2",
      "provider_config" => %{"account_pool" => "codex"}
    }
  end

  defp validate_server_credentials(_attrs, nil), do: :ok

  defp validate_server_credentials(attrs, _tenant_id) do
    configs =
      Map.take(
        attrs,
        ~w(provider_config image_config video_config vision_describer_config analyze_config)
      )

    if server_credential_reference?(configs),
      do:
        {:error,
         {:bad_request,
          "private templates cannot reference server credential environment variables"}},
      else: :ok
  end

  defp server_credential_reference?(value) when is_map(value) do
    Enum.any?(value, fn {key, nested} ->
      (to_string(key) in ~w(api_key_env auth_token_env) and nested not in [nil, ""]) or
        server_credential_reference?(nested)
    end)
  end

  defp server_credential_reference?(value) when is_list(value),
    do: Enum.any?(value, &server_credential_reference?/1)

  defp server_credential_reference?(_), do: false

  defp media_scope(config, %{"tenant_id" => tenant_id}) when is_binary(tenant_id) do
    config = config || %{}
    if config == %{}, do: config, else: Map.put(config, "credential_scope", "tenant")
  end

  defp media_scope(config, _template), do: config || %{}

  defp validate_create(attrs) do
    if present?(attrs["name"]) and present?(attrs["model"]) do
      :ok
    else
      {:error, {:bad_request, "name and model are required"}}
    end
  end

  defp canonicalize_model(%{"model" => model} = attrs),
    do: Map.put(attrs, "model", LLMProvider.canonical_model(model))

  defp canonicalize_model(attrs), do: attrs

  # GPT-5.6 supports Chat Completions, but OpenAI recommends Responses for
  # reasoning, tool-calling, and multi-turn workflows. Default only when the
  # template did not choose a protocol explicitly, so existing explicit Chat
  # Completions templates keep their requested wire protocol.
  defp default_openai_protocol(config, "openai", model)
       when model in ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"] do
    Map.put_new(config, "protocol", "responses")
  end

  defp default_openai_protocol(config, _provider, _model), do: config

  defp validate_config_objects(attrs) do
    Enum.reduce_while(
      ~w(image_config video_config vision_describer_config analyze_config),
      :ok,
      fn key, :ok ->
        case Map.fetch(attrs, key) do
          {:ok, value} when is_map(value) -> {:cont, :ok}
          {:ok, _value} -> {:halt, {:error, {:bad_request, "#{key} must be a JSON object"}}}
          :error -> {:cont, :ok}
        end
      end
    )
  end

  defp ensure_unreferenced(template_id, tenant_id) when is_binary(tenant_id) do
    with {:ok, %{objects: objects, next: next}} <-
           S3.list(Keys.ctl_agents_prefix_for_tenant(tenant_id), max_keys: 101),
         true <- length(objects) <= 100 and is_nil(next) do
      objects
      |> Task.async_stream(fn %{key: key} -> get_record(key) end,
        max_concurrency: 8,
        timeout: 10_000,
        on_timeout: :kill_task
      )
      |> Enum.reduce_while(:ok, fn
        {:ok, {:ok, record}}, :ok when is_map(record) ->
          if record["template_id"] == template_id and not Map.has_key?(record, "archived_at"),
            do:
              {:halt,
               {:error,
                {:conflict,
                 "This template is assigned to an Agent. Change its model before deleting the template."}}},
            else: {:cont, :ok}

        _, _ ->
          {:halt,
           {:error, {:conflict, "Could not verify Agent references. Retry deletion later."}}}
      end)
    else
      false ->
        {:error,
         {:conflict,
          "This organization exceeds the interactive deletion scan limit. Contact an administrator to remove this template."}}

      error ->
        error
    end
  end

  defp ensure_unreferenced(template_id, nil) do
    refs =
      Keys.ctl_agents_prefix()
      |> list_records()
      |> Enum.count(&(&1["template_id"] == template_id and not Map.has_key?(&1, "archived_at")))

    if refs == 0 do
      :ok
    else
      {:error, {:conflict, "template is referenced by #{refs} agent(s)"}}
    end
  end

  defp list_records(prefix) do
    case S3.list_all(prefix) do
      {:ok, objects} ->
        context = SystemsObservability.Context.capture()

        objects
        |> Task.async_stream(
          fn %{key: key} ->
            SystemsObservability.Context.run(context, fn ->
              case get_record(key) do
                {:ok, rec} -> [rec]
                _ -> []
              end
            end)
          end,
          max_concurrency: @list_read_concurrency,
          ordered: true,
          timeout: :infinity
        )
        |> Enum.flat_map(fn {:ok, records} -> records end)

      {:error, _} ->
        []
    end
  end

  defp ensure_catalog_bound(objects, nil, limit) when length(objects) <= limit, do: :ok
  defp ensure_catalog_bound(_objects, _next, _limit), do: {:error, :model_catalog_too_large}

  defp read_bounded_records(objects) do
    context = SystemsObservability.Context.capture()

    objects
    |> Task.async_stream(
      fn %{key: key} ->
        SystemsObservability.Context.run(context, fn -> read_bounded_record(key) end)
      end,
      max_concurrency: @list_read_concurrency,
      ordered: true,
      timeout: :infinity
    )
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, {:ok, records}}, {:ok, acc} -> {:cont, {:ok, [records | acc]}}
      {:ok, {:error, reason}}, _acc -> {:halt, {:error, reason}}
      {:exit, reason}, _acc -> {:halt, {:error, reason}}
    end)
    |> case do
      {:ok, batches} -> {:ok, batches |> Enum.reverse() |> List.flatten()}
      {:error, _reason} = error -> error
    end
  end

  defp read_bounded_record(key) do
    case get_record(key) do
      {:ok, %{"template_id" => id, "name" => name, "model" => model} = record}
      when is_binary(id) and id != "" and is_binary(name) and name != "" and is_binary(model) and
             model != "" ->
        {:ok, [record]}

      {:ok, _invalid_record} ->
        {:ok, []}

      {:error, :not_found} ->
        {:ok, []}

      {:error, %Jason.DecodeError{}} ->
        {:ok, []}

      {:error, _reason} = error ->
        error
    end
  end

  defp get_record(key) do
    case S3.get(key) do
      {:ok, %{body: body}} -> Jason.decode(body)
      {:error, _} = err -> err
    end
  end

  defp put_new(key, rec) do
    case S3.put(key, Jason.encode!(rec), if_none_match: "*") do
      {:ok, _} -> {:ok, rec}
      {:error, :precondition_failed} -> {:error, :exists}
      {:error, reason} -> {:error, reason}
    end
  end

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: not is_nil(value)

  defp now, do: System.system_time(:second)
  defp random_id, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
end
