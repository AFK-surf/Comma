defmodule SalixIM.Provider.Feishu.AppAvailability do
  @moduledoc """
  Whether a connect's Feishu app is available to one person (the app's
  availability range, which the tenant's administrators set in the Feishu
  admin console), and who that person is.

  `CommaWeb.Stations` asks it on every station tool call of a person who has
  no account in the product (`SalixStore.StationMembers.app_member_role/2`),
  so an administrator's change applies to the next call. The person's name
  and email are kept per connect and person for at most an hour, in a table
  of at most 10,000 entries that the connect API process owns
  (`SalixIM.Provider.Feishu.API`); availability itself is never kept.

  Availability needs the app permission `application:application:self_manage`;
  the email needs `contact:user.email:readonly`.

  The twin of `SalixIM.Provider.Lark.AppAvailability`.
  """

  alias SalixIM.Provider.Feishu.API

  @cache_table :salix_im_feishu_app_member_cache
  @email_scope "contact:user.email:readonly"
  @cache_ttl_ms 3_600_000
  @cache_max 10_000

  @type failure ::
          :not_available | :no_email | {:missing_scope, String.t()} | String.t()

  @doc """
  The person `open_id` as the connect's app knows them, `%{"name", "email"}`,
  when the app is available to them: their item of the app's visibility check
  is on the white list and not on the black list. A person the check does not
  list is not available. The user is read only for a person it is available
  to. An empty email is `{:missing_scope, "contact:user.email:readonly"}`
  when the app's granted scopes lack that permission, else `:no_email`.
  """
  @spec member(map(), String.t()) :: {:ok, map()} | {:error, failure()}
  def member(connect, open_id) when is_map(connect) and is_binary(open_id) and open_id != "" do
    with :ok <- available(connect, open_id), do: person(connect, open_id)
  end

  def member(_connect, _open_id), do: {:error, :not_available}

  @doc false
  def create_cache do
    SystemsRuntime.ETS.new(@cache_table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    :ok
  end

  @doc false
  def reset_cache do
    case SystemsRuntime.ETS.whereis(@cache_table) do
      :undefined -> :ok
      table -> SystemsRuntime.ETS.delete_all_objects(table)
    end

    :ok
  end

  defp available(connect, open_id) do
    with {:ok, app_id} <- API.app_id(connect),
         {:ok, data} <-
           API.post_read(
             connect,
             "/application/v6/applications/#{URI.encode_www_form(app_id)}" <>
               "/visibility/check_white_black_list?user_id_type=open_id",
             %{"user_ids" => [open_id]}
           ) do
      items = if is_map(data), do: List.wrap(data["user_visibility_list"]), else: []

      case Enum.find(items, &(is_map(&1) and &1["user_id"] == open_id)) do
        %{"in_white_list" => true, "in_black_list" => true} -> {:error, :not_available}
        %{"in_white_list" => true} -> :ok
        _not_listed -> {:error, :not_available}
      end
    else
      {:error, reason} -> {:error, failure(reason)}
    end
  end

  defp person(connect, open_id) do
    key = {connect["connect_id"], open_id}

    case cached(key) do
      {:ok, person} ->
        {:ok, person}

      :miss ->
        with {:ok, data} <-
               API.get(connect, "/contact/v3/users/#{URI.encode_www_form(open_id)}", %{
                 user_id_type: "open_id"
               }) do
          user = if is_map(data) and is_map(data["user"]), do: data["user"], else: %{}

          case Enum.find([user["email"], user["enterprise_email"]], &(is_binary(&1) and &1 != "")) do
            nil ->
              {:error, no_email(connect)}

            email ->
              person = %{"name" => user["name"], "email" => email}
              keep(key, person)
              {:ok, person}
          end
        else
          {:error, reason} -> {:error, failure(reason)}
        end
    end
  end

  # The directory gives no email both to a person who has none and to an app
  # without the email permission: the app's granted scopes tell which. When
  # they cannot be read, no email is the best known cause.
  defp no_email(connect) do
    case API.get(connect, "/application/v6/scopes") do
      {:ok, %{"scopes" => scopes}} when is_list(scopes) ->
        if Enum.any?(scopes, &granted_email_scope?/1),
          do: :no_email,
          else: {:missing_scope, @email_scope}

      _unknown ->
        :no_email
    end
  end

  defp granted_email_scope?(%{
         "scope_name" => @email_scope,
         "grant_status" => 1,
         "scope_type" => "tenant"
       }),
       do: true

  defp granted_email_scope?(_scope), do: false

  defp failure(reason) do
    case API.missing_scope(reason) do
      nil -> reason
      scope -> {:missing_scope, scope}
    end
  end

  defp cached(key) do
    now = SystemsClock.monotonic_time(:millisecond)

    with table when table != :undefined <- SystemsRuntime.ETS.whereis(@cache_table),
         [{^key, person, expires_at}] when expires_at > now <-
           SystemsRuntime.ETS.lookup(table, key) do
      {:ok, person}
    else
      _miss -> :miss
    end
  end

  defp keep(key, person) do
    case SystemsRuntime.ETS.whereis(@cache_table) do
      :undefined ->
        :ok

      table ->
        if SystemsRuntime.ETS.info(table, :size) >= @cache_max,
          do: SystemsRuntime.ETS.delete_all_objects(table)

        expires_at = SystemsClock.monotonic_time(:millisecond) + @cache_ttl_ms
        SystemsRuntime.ETS.insert(table, {key, person, expires_at})
        :ok
    end
  end
end
