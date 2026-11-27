defmodule Salix.Control.M2squareSettings do
  @moduledoc """
  Control-plane storage for platform-wide M2square Teams billing toggles
  (`ctl/system/m2square_settings.json` in `SalixStore.S3`).

  All four supported LATAM countries (`PE`, `EC`, `BR`, `CL`) default to
  disabled (`enabled: false`) when unconfigured. Conditional writes (`if_none_match`
  on first write, `if_match` on updates) prevent lost updates across concurrent
  Salix Admin operators, and `{:ambiguous, _}` outcomes settle via explicit
  read-back before reporting state.
  """

  alias SalixStore.{Keys, ReadScope, S3}

  @schema_version 1
  @unconfigured_etag "__unconfigured__"
  @country_order ["PE", "EC", "BR", "CL"]

  @supported_payment_types %{
    "PE" => ["NET_BANKING", "TD", "TC", "CASH"],
    "EC" => ["NET_BANKING", "CASH"],
    "BR" => ["PIX"],
    "CL" => ["NET_BANKING", "TD", "TC", "CASH"]
  }

  @default_payment_types %{
    "PE" => ["NET_BANKING", "TD", "TC"],
    "EC" => ["NET_BANKING"],
    "BR" => ["PIX"],
    "CL" => ["NET_BANKING", "TD", "TC"]
  }

  @doc "Sentinel ETag representing an unconfigured (not-yet-created) settings object."
  @spec unconfigured_etag() :: String.t()
  def unconfigured_etag, do: @unconfigured_etag

  @doc "Canonical display order of supported M2square country codes."
  @spec country_order() :: [String.t()]
  def country_order, do: @country_order

  @doc "Supported payment types in canonical order for `country_code`."
  @spec supported_payment_types(String.t()) :: [String.t()]
  def supported_payment_types(country_code),
    do: Map.get(@supported_payment_types, country_code, [])

  @doc "Default all-disabled country map used by the admin UI prior to first save."
  @spec default_all_disabled_countries() :: map()
  def default_all_disabled_countries do
    Map.new(@country_order, fn code ->
      {code, %{"enabled" => false, "payment_types" => Map.fetch!(@default_payment_types, code)}}
    end)
  end

  @doc """
  Reads and strictly validates the persisted M2square settings.

  Returns:
    * `{:ok, {:configured, countries}}` when a valid v1 record exists,
    * `{:ok, :unconfigured}` when the S3 key does not exist yet,
    * `{:error, :invalid_m2square_settings}` when stored JSON violates the schema,
    * `{:error, reason}` on storage failure.
  """
  @spec get() :: {:ok, {:configured, map()} | :unconfigured} | {:error, term()}
  def get do
    case S3.get(Keys.ctl_system_m2square_settings()) do
      {:ok, %{body: body}} ->
        case decode_and_validate_stored(body) do
          {:ok, countries} -> {:ok, {:configured, countries}}
          {:error, _} = err -> err
        end

      {:error, :not_found} ->
        {:ok, :unconfigured}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Reads the authoritative M2square settings for the Salix Admin UI, including ETag.
  """
  @spec get_for_admin() ::
          {:ok, %{configured?: boolean(), countries: map(), etag: String.t()}}
          | {:error, term()}
  def get_for_admin do
    case S3.get(Keys.ctl_system_m2square_settings()) do
      {:ok, %{body: body, etag: etag}} when is_binary(etag) and etag != "" ->
        case decode_and_validate_stored(body) do
          {:ok, countries} ->
            {:ok, %{configured?: true, countries: countries, etag: etag}}

          {:error, _} = err ->
            err
        end

      {:ok, %{body: _body}} ->
        {:error, :invalid_etag}

      {:error, :not_found} ->
        {:ok,
         %{
           configured?: false,
           countries: default_all_disabled_countries(),
           etag: @unconfigured_etag
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Validates and conditionally persists M2square settings using CAS (`if_none_match`
  for `"__unconfigured__"` or `if_match` for an existing opaque ETag).
  """
  @spec put(map(), term()) ::
          {:ok, {:saved, map(), String.t()} | {:already_applied, map(), String.t()}}
          | {:error, term()}
  def put(countries_input, expected_etag) do
    with {:ok, put_opts} <- build_cas_opts(expected_etag),
         {:ok, normalized_countries} <- validate_put_input(countries_input) do
      key = Keys.ctl_system_m2square_settings()

      payload =
        Jason.encode!(%{
          "version" => @schema_version,
          "countries" => normalized_countries,
          "updated_at" => DateTime.to_iso8601(SystemsClock.utc_now())
        })

      ReadScope.invalidate({:record, key})

      case S3.put(key, payload, put_opts) do
        {:ok, %{etag: new_etag}} when is_binary(new_etag) and new_etag != "" ->
          {:ok, {:saved, normalized_countries, new_etag}}

        {:ok, _other} ->
          {:error, :invalid_etag}

        {:error, :precondition_failed} ->
          {:error, :conflict}

        {:error, {:ambiguous, _reason}} ->
          settle_ambiguous(normalized_countries)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp build_cas_opts(@unconfigured_etag), do: {:ok, [if_none_match: "*"]}

  defp build_cas_opts(etag) when is_binary(etag) do
    if String.trim(etag) != "" do
      {:ok, [if_match: etag]}
    else
      {:error, :invalid_etag}
    end
  end

  defp build_cas_opts(_), do: {:error, :invalid_etag}

  defp settle_ambiguous(normalized_countries) do
    case get_for_admin() do
      {:ok, %{configured?: false} = state} ->
        {:error, {:unconfigured_after_ambiguous, state}}

      {:ok, %{configured?: true, countries: live_countries, etag: live_etag}}
      when live_countries == normalized_countries ->
        {:ok, {:already_applied, live_countries, live_etag}}

      {:ok, %{configured?: true} = state} ->
        {:error, {:conflict_settled, state}}

      {:error, _reason} ->
        {:error, :ambiguous_unconfirmed}
    end
  end

  defp decode_and_validate_stored(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok,
       %{
         "version" => @schema_version,
         "countries" => %{} = countries,
         "updated_at" => updated_at
       } = decoded}
      when map_size(decoded) == 3 and is_binary(updated_at) ->
        case DateTime.from_iso8601(updated_at) do
          {:ok, %DateTime{}, _offset} -> validate_stored_countries(countries)
          _ -> {:error, :invalid_m2square_settings}
        end

      _ ->
        {:error, :invalid_m2square_settings}
    end
  end

  defp decode_and_validate_stored(_), do: {:error, :invalid_m2square_settings}

  defp validate_stored_countries(countries) do
    keys = Map.keys(countries)

    if length(keys) == length(@country_order) and
         Enum.all?(@country_order, &Map.has_key?(countries, &1)) do
      Enum.reduce_while(@country_order, {:ok, %{}}, fn code, {:ok, acc} ->
        case validate_stored_country(code, Map.fetch!(countries, code)) do
          {:ok, entry} -> {:cont, {:ok, Map.put(acc, code, entry)}}
          :error -> {:halt, {:error, :invalid_m2square_settings}}
        end
      end)
    else
      {:error, :invalid_m2square_settings}
    end
  end

  defp validate_stored_country(code, %{"enabled" => enabled, "payment_types" => payment_types})
       when is_boolean(enabled) and is_list(payment_types) do
    supported = Map.fetch!(@supported_payment_types, code)

    if Enum.all?(payment_types, &is_binary/1) do
      canonical = Enum.filter(supported, &(&1 in payment_types))

      if payment_types == canonical and (not enabled or payment_types != []) do
        {:ok, %{"enabled" => enabled, "payment_types" => payment_types}}
      else
        :error
      end
    else
      :error
    end
  end

  defp validate_stored_country(_code, _entry), do: :error

  defp validate_put_input(%{} = input) do
    normalized_keys =
      Enum.reduce(input, %{}, fn {k, v}, acc ->
        Map.put(acc, to_string(k) |> String.trim() |> String.upcase(), v)
      end)

    unknown_keys = Map.keys(normalized_keys) -- @country_order

    if unknown_keys != [] do
      errors = Map.new(unknown_keys, &{&1, :unsupported_country})
      {:error, {:validation, errors}}
    else
      {countries, errors} =
        Enum.reduce(@country_order, {%{}, %{}}, fn code, {acc, errs} ->
          case Map.fetch(normalized_keys, code) do
            :error ->
              {acc, Map.put(errs, code, :missing_country)}

            {:ok, raw_entry} ->
              case validate_put_country(code, raw_entry) do
                {:ok, entry} -> {Map.put(acc, code, entry), errs}
                {:error, reason} -> {acc, Map.put(errs, code, reason)}
              end
          end
        end)

      if map_size(errors) == 0 do
        {:ok, countries}
      else
        {:error, {:validation, errors}}
      end
    end
  end

  defp validate_put_input(_), do: {:error, {:validation, %{"_base" => :invalid_countries}}}

  defp validate_put_country(code, %{} = raw_entry) do
    enabled = fetch_field(raw_entry, "enabled", :enabled)
    payment_types = fetch_field(raw_entry, "payment_types", :payment_types)
    supported = Map.fetch!(@supported_payment_types, code)

    cond do
      not is_boolean(enabled) ->
        {:error, :invalid_enabled}

      not is_list(payment_types) or not Enum.all?(payment_types, &is_binary/1) ->
        {:error, :invalid_payment_types}

      true ->
        normalized_pts = Enum.map(payment_types, &(&1 |> String.trim() |> String.upcase()))
        unknown = Enum.reject(normalized_pts, &(&1 in supported))

        cond do
          unknown != [] ->
            {:error, :unsupported_payment_type}

          true ->
            canonical = Enum.filter(supported, &(&1 in normalized_pts))

            if enabled and canonical == [] do
              {:error, :payment_types_required_when_enabled}
            else
              {:ok, %{"enabled" => enabled, "payment_types" => canonical}}
            end
        end
    end
  end

  defp validate_put_country(_code, _entry), do: {:error, :invalid_country_entry}

  defp fetch_field(map, str_key, atom_key) do
    case Map.fetch(map, str_key) do
      {:ok, val} -> val
      :error -> Map.get(map, atom_key)
    end
  end
end
