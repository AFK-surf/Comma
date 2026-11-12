defmodule SalixStore.OAuth.Adapters.Secret do
  @moduledoc """
  A value a person types in, kept and used as an OAuth credential is: an API key
  or a token with no OAuth behind it. The authorization link opens a form in
  Salix (`SalixWeb.OAuthCallbackPage.render_secret_form/3`) instead of a
  provider's page, and what the form posts is the "code" of the usual callback.
  Nothing expires and nothing refreshes it.

  A secret may instead carry named fields (an app id and its secret, a user and
  a password, a tenant id): the request names them (`fields/1`), the form asks
  for each, and the connection record keeps them in order under `"fields"`, next
  to where a single value keeps its `"access_token"`. `credential_env` names a
  field by its `value`. Only a secret field's value is redacted from output.
  """
  @behaviour SalixStore.OAuth.Adapter

  alias SalixStore.OAuth.Adapter

  @max_bytes 64 * 1024
  @max_fields 8
  @max_label 80
  # The value names a credential without fields already answers to.
  @reserved ~w(access_token client_id)
  @field_name ~r/\A[A-Za-z][A-Za-z0-9_]{0,31}\z/

  @impl true
  def default_env_var, do: "SECRET_VALUE"

  @doc """
  The fields a request asks for, normalized to `[%{"name", "label", "secret"}]`
  in their order; nil or `[]` is a single value. A name is letters, digits and
  `_`, starts with a letter, has at most 32 characters, is unique ignoring case
  and is not `access_token` or `client_id`; at most 8 fields. `label` (what the
  form shows) defaults to the name, `secret` to true.
  """
  @spec fields(term()) :: {:ok, [map()]} | {:error, String.t()}
  def fields(nil), do: {:ok, []}

  def fields(list) when is_list(list) and length(list) <= @max_fields do
    list
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case field(entry) do
        {:ok, %{"name" => name} = field} ->
          if Enum.any?(acc, &(String.downcase(&1["name"]) == String.downcase(name))),
            do: {:halt, {:error, "field #{name} is given twice"}},
            else: {:cont, {:ok, [field | acc]}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, fields} -> {:ok, Enum.reverse(fields)}
      error -> error
    end
  end

  def fields(list) when is_list(list), do: {:error, "a secret has at most #{@max_fields} fields"}
  def fields(_other), do: {:error, "fields must be a list of {name, label, secret}"}

  defp field(entry) when is_map(entry) do
    name = entry |> get("name") |> to_text()
    label = entry |> get("label") |> to_text()

    cond do
      not Regex.match?(@field_name, name) ->
        {:error,
         "field name #{inspect(name)} must be letters, digits and _, start with a letter, and have at most 32 characters"}

      String.downcase(name) in @reserved ->
        {:error, "field name #{name} is reserved"}

      String.length(label) > @max_label ->
        {:error, "field #{name}: label has more than #{@max_label} characters"}

      get(entry, "secret") not in [nil, true, false] ->
        {:error, "field #{name}: secret must be true or false"}

      true ->
        {:ok,
         %{
           "name" => name,
           "label" => if(label == "", do: name, else: label),
           "secret" => get(entry, "secret") != false
         }}
    end
  end

  defp field(_entry), do: {:error, "fields must be a list of {name, label, secret}"}

  defp get(map, key), do: Map.get(map, key, Map.get(map, String.to_atom(key)))

  defp to_text(value) when is_binary(value), do: String.trim(value)
  defp to_text(_value), do: ""

  @doc "The names and secret flags of a connection's fields, without their values."
  @spec field_names(map()) :: [map()]
  def field_names(%{"fields" => fields}) when is_list(fields),
    do: Enum.map(fields, &%{"name" => &1["name"], "secret" => &1["secret"] != false})

  def field_names(_conn), do: []

  @doc """
  Whether `value`, as `credential_env` names it, is a secret of `conn`: every
  value is, except a field marked not secret.
  """
  @spec secret_value?(map(), String.t()) :: boolean()
  def secret_value?(conn, value) do
    case find_field(conn, value) do
      %{"secret" => false} -> false
      _ -> true
    end
  end

  @impl true
  def authorization_url(_app, req) do
    if Adapter.blank?(req["redirect_uri"]),
      do: {:error, "secret: redirect_uri is required"},
      else: {:ok, req["redirect_uri"] <> "?" <> URI.encode_query(%{"state" => req["state"]})}
  end

  # A request with fields takes exactly those, each a value of its own.
  @impl true
  def exchange_code(_app, %{"fields" => [_ | _] = wanted}, values) when is_map(values) do
    given = Map.keys(values) |> Enum.map(&to_string/1) |> Enum.sort()
    names = Enum.map(wanted, & &1["name"])

    if given != Enum.sort(names) do
      {:error, "expected the fields #{Enum.join(names, ", ")}"}
    else
      Enum.reduce_while(Enum.reverse(wanted), {:ok, []}, fn field, {:ok, acc} ->
        case value(values[field["name"]]) do
          {:ok, value} ->
            {:cont,
             {:ok,
              [%{"name" => field["name"], "secret" => field["secret"], "value" => value} | acc]}}

          {:error, reason} ->
            {:halt, {:error, "#{field["name"]}: #{reason}"}}
        end
      end)
      |> case do
        {:ok, fields} -> {:ok, tokens(nil, fields)}
        error -> error
      end
    end
  end

  def exchange_code(_app, %{"fields" => [_ | _] = wanted}, _value),
    do: {:error, "expected the fields #{Enum.map_join(wanted, ", ", & &1["name"])}"}

  def exchange_code(_app, _ctx, value) do
    with {:ok, value} <- value(value), do: {:ok, tokens(value, nil)}
  end

  defp value(value) when is_binary(value) and byte_size(value) <= @max_bytes do
    case String.trim(value) do
      "" -> {:error, "the value is empty"}
      value -> {:ok, value}
    end
  end

  defp value(value) when is_binary(value), do: {:error, "the value is too long"}
  defp value(_value), do: {:error, "the value is empty"}

  defp tokens(access_token, fields) do
    %{
      "tokens" =>
        %{
          "access_token" => access_token,
          "refresh_token" => nil,
          "expires_at" => nil,
          "refresh_expires_at" => nil,
          "token_type" => "secret",
          "scopes" => []
        }
        |> then(&if(fields, do: Map.put(&1, "fields", fields), else: &1)),
      "account" => %{"provider_account_id" => "", "provider_account_name" => ""}
    }
  end

  @impl true
  def refresh(_app, conn), do: {:ok, Adapter.passthrough_tokens(conn)}

  @impl true
  def revoke(_app, _conn), do: {:error, :revocation_not_supported}

  # Which names a credential has is known only with its record.
  @impl true
  def validate_credential_value(_value, _scopes), do: :ok

  @impl true
  def resolve_credential_value(%{"fields" => [_ | _] = fields} = conn, value) do
    case find_field(conn, value) do
      %{"value" => found} ->
        {:ok, found}

      nil ->
        {:error,
         "secret: no field #{inspect(value)}; its fields are #{Enum.map_join(fields, ", ", & &1["name"])}"}
    end
  end

  def resolve_credential_value(conn, value),
    do: Adapter.resolve_access_token(conn, value, "secret")

  defp find_field(%{"fields" => fields}, value) when is_list(fields) do
    name = String.downcase(to_string(value))
    Enum.find(fields, &(String.downcase(to_string(&1["name"])) == name))
  end

  defp find_field(_conn, _value), do: nil
end
