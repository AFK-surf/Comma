defmodule BridgeForTeamsWeb.DashboardModelAccounts do
  @moduledoc """
  The private templates and organization accounts sections of Settings → AI
  models, for `DashboardAPIController`.

  Organization accounts are Codex and Claude subscriptions and Provider API
  keys stored in Salix; private templates use them. `BridgeForTeams.Subscriptions`
  checks owner/admin again for every call and scopes it to the organization's
  Salix tenant, so no tenant or account scope comes from the browser.

  Each request makes the controller's membership queries, the owner/admin
  check and one Salix call (two for a write, which returns the refreshed list).
  Salix pages accounts and workload bindings 25 at a time; the projects of a
  bindings page load in one query.
  """
  use Gettext, backend: BridgeForTeamsWeb.Gettext

  alias BridgeForTeams.Subscriptions
  alias BridgeForTeamsWeb.DashboardSettings

  @providers ~w(codex claude)
  @template_fields ~w(template_id name model model_display_name model_vendor max_tokens
                      subscription_provider)
  @template_params ~w(name subscription_provider model model_display_name model_vendor max_tokens)
  @account_fields ~w(id version credential_kind provider name email status disabled quota
                     reset_attempt connection compatible_runtimes)

  # ---- Private templates ----

  def templates(org, user) do
    case Subscriptions.templates(scope(org, user)) do
      {:ok, templates} ->
        {:ok, %{"templates" => Enum.map(templates, &Map.take(&1, @template_fields))}}

      error ->
        reply(error)
    end
  end

  @doc "Create a template (`id` nil) or update one; returns the refreshed list."
  def save_template(org, user, id, params) do
    case Subscriptions.save_template(scope(org, user), id, Map.take(params, @template_params)) do
      {:ok, _template} -> templates(org, user)
      error -> reply(error)
    end
  end

  def delete_template(org, user, id) do
    case Subscriptions.delete_template(scope(org, user), id) do
      :ok -> templates(org, user)
      {:ok, _} -> templates(org, user)
      error -> reply(error)
    end
  end

  @doc "The models a connected subscription offers, for the template editor."
  def discover_models(org, user, %{"subscription_provider" => provider})
      when provider in @providers do
    case Subscriptions.discover_models(scope(org, user), provider) do
      {:ok, result} ->
        {:ok,
         %{
           "models" => Enum.map(result["data"] || [], &Map.take(&1, ~w(id name vendor))),
           "truncated" => result["truncated"] == true
         }}

      error ->
        reply(error)
    end
  end

  def discover_models(_org, _user, _params), do: reply({:error, :invalid_input})

  # ---- Organization accounts ----

  def accounts(org, user, cursor) do
    case Subscriptions.list(scope(org, user), cursor(cursor)) do
      {:ok, page} ->
        {:ok,
         %{
           "accounts" => Enum.map(page["accounts"], &Map.take(&1, @account_fields)),
           "next" => blank_to_nil(page["next"])
         }}

      error ->
        reply(error)
    end
  end

  @doc """
  Add a Provider API key (`kind: "provider_api_key"`) or import subscription
  credentials (`kind: "subscription"`, a parsed credential file).
  """
  def create_account(org, user, %{"kind" => "provider_api_key"} = params) do
    params
    |> Map.take(~w(name connection credentials))
    |> Map.put("credential_kind", "provider_api_key")
    |> then(&write(org, user, params, fn scope -> Subscriptions.create(scope, &1) end))
  end

  def create_account(
        org,
        user,
        %{"kind" => "subscription", "provider" => provider, "credentials" => credentials} =
          params
      )
      when provider in @providers and is_map(credentials) do
    write(org, user, params, fn scope ->
      Subscriptions.create(scope, %{"provider" => provider, "credentials" => credentials})
    end)
  end

  def create_account(_org, _user, _params), do: reply({:error, :invalid_input})

  @doc """
  Enable or disable an account, rename it, change a Provider API key's
  connection, or replace credentials. `version` must match the stored account.
  """
  def update_account(org, user, id, params) do
    attrs = Map.take(params, ~w(version disabled name connection credentials))
    write(org, user, params, &Subscriptions.update(&1, id, attrs))
  end

  def delete_account(org, user, id, params),
    do: write(org, user, params, &Subscriptions.delete(&1, id, params["version"]))

  def refresh_quota(org, user, id, params),
    do: write(org, user, params, &Subscriptions.quota(&1, id))

  @doc """
  Use one Codex reset credit. The client sends the `request_id` of a pending
  attempt again, so a retry checks that attempt instead of spending another
  credit.
  """
  def reset_quota(org, user, id, params) do
    case Subscriptions.reset_quota(scope(org, user), id, params) do
      {:ok, result} ->
        {:ok,
         %{
           "outcome" => result["outcome"],
           "quota_refreshed" => result["quota_refreshed"] == true,
           "account" => Map.take(result["account"] || %{}, @account_fields)
         }}

      error ->
        reply(error)
    end
  end

  def account_usage(org, user, id, cursor) do
    case Subscriptions.list_bindings(scope(org, user), id, usage_cursor(cursor)) do
      {:ok, page} ->
        {:ok,
         %{
           "bindings" => Enum.map(page["bindings"], &public_binding(org, &1)),
           "hidden_count" => page["hidden_count"],
           "next" => page["next"]
         }}

      error ->
        reply(error)
    end
  end

  @doc """
  Start an authorization: Codex uses the device flow, Claude a callback URL
  the admin pastes back. With `account_id` it reauthorizes that account.
  """
  def begin_oauth(org, user, %{"provider" => provider} = params) when provider in @providers do
    attrs =
      params
      |> Map.take(~w(provider account_id version))
      |> Map.put("mode", if(provider == "codex", do: "device", else: "callback"))

    case Subscriptions.begin_oauth(scope(org, user), attrs) do
      # `href`, not `url`: the response sanitizer rewrites the query of `*url` keys.
      {:ok, attempt} ->
        {:ok,
         attempt
         |> Map.take(~w(id user_code interval expires_at))
         |> Map.merge(%{"mode" => attrs["mode"], "href" => attempt["url"]})}

      error ->
        reply(error)
    end
  end

  def begin_oauth(_org, _user, _params), do: reply({:error, :invalid_input})

  @doc "Complete an authorization; an empty `code` polls a device attempt."
  def complete_oauth(org, user, attempt_id, params) do
    code = if is_binary(params["code"]), do: params["code"], else: ""

    case Subscriptions.complete_oauth(scope(org, user), attempt_id, %{"code" => code}) do
      {:ok, %{"status" => "pending"} = pending} ->
        {:ok, %{"status" => "pending", "interval" => pending["interval"]}}

      {:ok, _account} ->
        {:ok, %{"status" => "connected"}}

      error ->
        reply(error)
    end
  end

  # ---- helpers ----

  defp write(org, user, params, operation) do
    case operation.(scope(org, user)) do
      {:ok, _} -> accounts(org, user, params["cursor"])
      error -> reply(error)
    end
  end

  defp public_binding(org, binding) do
    project = binding["project"]
    workload = binding["workload_id"]

    %{
      "project" => Map.take(project, ~w(id name)),
      "workload_id" => workload,
      "href" =>
        if is_binary(workload) do
          "/orgs/#{org.slug}/projects/#{project["id"]}/devices?" <>
            URI.encode_query(%{"runtime_auth_target" => workload})
        end
    }
  end

  defp scope(org, user), do: {org.id, user.id}

  defp cursor(value) when is_binary(value), do: value
  defp cursor(_value), do: ""

  defp usage_cursor(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n >= 0 -> n
      _ -> 0
    end
  end

  defp usage_cursor(value) when is_integer(value) and value >= 0, do: value
  defp usage_cursor(_value), do: 0

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  defp reply({:error, :forbidden}), do: DashboardSettings.forbidden()

  defp reply({:error, reason}) when reason in [:unavailable, :timeout],
    do:
      {:error, 503, "runtime_unavailable",
       gettext("The runtime is unavailable right now. Retry shortly."), %{}}

  # Salix and template validation messages are passed on as they are.
  defp reply({:error, {:bad_request, message}}) when is_binary(message),
    do: {:error, 422, "invalid", message, %{}}

  defp reply({:error, {:conflict, message}}) when is_binary(message),
    do: {:error, 409, "conflict", message, %{}}

  defp reply({:error, reason}) when is_atom(reason) do
    {status, message} = message(reason)
    {:error, status, Atom.to_string(reason), message, %{}}
  end

  defp reply(_error),
    do:
      {:error, 500, "write_failed",
       gettext("Could not complete this operation. Refresh the page and try again."), %{}}

  defp message(:invalid_input),
    do:
      {422,
       gettext(
         "Invalid credentials or authorization code. Check the input and start authorization again if needed."
       )}

  defp message(:conflict),
    do: {409, gettext("This account changed. Refresh the list and try again.")}

  defp message(:account_in_use),
    do:
      {409,
       gettext(
         "A workload still uses this account. Open its usage and unbind every workload first."
       )}

  defp message(:not_found),
    do: {409, gettext("This item is no longer available. Refresh the list and try again.")}

  defp message(:reset_pending),
    do:
      {409,
       gettext(
         "The reset result is not confirmed. Retry the same reset to check its result without using another reset credit."
       )}

  defp message(:reset_in_progress),
    do: {409, gettext("Another reset is pending. Refresh the list to resume that request.")}

  defp message(reason) when reason in [:authorization_expired, :authorization_unavailable],
    do:
      {409,
       gettext(
         "This authorization expired or was already used. Start again and use the new link."
       )}

  defp message(:model_catalog_too_large),
    do:
      {422,
       gettext(
         "The model catalog exceeds the 100-template interactive limit. Contact a platform administrator."
       )}

  defp message(_reason),
    do: {500, gettext("Could not complete this operation. Refresh the page and try again.")}
end
