defmodule Comma.MiniApps.Config do
  @moduledoc """
  Mini App server settings, `config :comma_core, :mini_apps` (runtime.exs reads
  them from the JSON config section `comma.mini_apps`):

    * `dispatch_base_url`, `dispatch_secret`: the private dispatch Worker and
      the HMAC secret it shares with this server;
    * `cloudflare_account_id`, `cloudflare_api_token`, `dispatch_namespace`:
      the Workers for Platforms namespace that holds app scripts;
    * `viewer_key` (at least 32 bytes): the key of pairwise viewer IDs;
    * `template_repo` (`"AFK-surf/comma-app-template"`): the public template;
    * `link_base_url` (`"https://app.comma.surf/a/"`): where a link token opens;
    * `app_storage_module_path`: the built `AppStorage` module, when no copy
      was compiled in.
  """

  @defaults [
    template_repo: "AFK-surf/comma-app-template",
    link_base_url: "https://app.comma.surf/a/"
  ]

  @doc "One setting, or its default."
  def get(key) when is_atom(key) do
    config = SystemsRuntime.get_env(:comma_core, :mini_apps, [])

    case Keyword.get(config, key) do
      value when is_binary(value) and value != "" -> value
      nil -> Keyword.get(@defaults, key)
      "" -> Keyword.get(@defaults, key)
      value -> value
    end
  end

  @doc "The key of pairwise viewer IDs, or `{:error, :mini_apps_unavailable}`."
  def viewer_key do
    case get(:viewer_key) do
      key when is_binary(key) and byte_size(key) >= 32 -> {:ok, key}
      _ -> {:error, :mini_apps_unavailable}
    end
  end

  @doc "The template repository as `{owner, name}`."
  def template_repo do
    case String.split(get(:template_repo), "/", parts: 2) do
      [owner, name] when owner != "" and name != "" -> {owner, name}
      _ -> {"AFK-surf", "comma-app-template"}
    end
  end

  @doc "The Cloudflare settings the adapter needs, or `{:error, :backend_unavailable}`."
  def cloudflare do
    values = %{
      account_id: get(:cloudflare_account_id),
      api_token: get(:cloudflare_api_token),
      namespace: get(:dispatch_namespace)
    }

    if Enum.all?(values, fn {_key, value} -> is_binary(value) and value != "" end),
      do: {:ok, values},
      else: {:error, :backend_unavailable}
  end

  @doc "The dispatch Worker's base URL and secret, or `{:error, :backend_unavailable}`."
  def dispatch do
    case {get(:dispatch_base_url), get(:dispatch_secret)} do
      {url, secret} when is_binary(url) and url != "" and is_binary(secret) and secret != "" ->
        {:ok, %{base_url: String.trim_trailing(url, "/"), secret: secret}}

      _ ->
        {:error, :backend_unavailable}
    end
  end
end
