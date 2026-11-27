defmodule BridgeForTeams.M2square.Payer do
  @moduledoc """
  Country-specific payer validation and M2square `pay` field assembly for
  PE, EC, BR, and CL.

  Returned `gateway_fields` are passed transiently to `BridgeForTeams.M2square.Client.pay/2`
  and must never be persisted to the database.
  """

  @email_regex ~r/\A[^\s@]+@[^\s@]+\.[^\s@]+\z/
  @ec_phone_regex ~r/\A[1-9][0-9]{5,8}\z/
  @general_phone_regex ~r/\A\+?[0-9\-\s()]{6,20}\z/

  @doc """
  Validates payer fields against `country_cfg` and builds the gateway payload fields.
  """
  @spec validate_and_build_pay_fields(map(), map()) ::
          {:ok, %{payment_type: String.t(), gateway_fields: map()}} | {:error, atom()}
  def validate_and_build_pay_fields(%{} = country_cfg, %{} = params) do
    with {:ok, firstname} <- validate_name(param(params, "firstname"), :invalid_firstname),
         {:ok, lastname} <- validate_name(param(params, "lastname"), :invalid_lastname),
         {:ok, email} <- validate_email(param(params, "email")),
         {:ok, phone} <- validate_phone(country_cfg.code, param(params, "phone")),
         {:ok, payment_type, country_fields} <- validate_country_fields(country_cfg, params) do
      base_fields = %{
        "firstname" => firstname,
        "lastname" => lastname,
        "email" => email,
        "phone" => phone
      }

      {:ok,
       %{
         payment_type: payment_type,
         gateway_fields: Map.merge(base_fields, country_fields)
       }}
    end
  end

  def validate_and_build_pay_fields(_country_cfg, _params), do: {:error, :invalid_params}

  defp validate_name(value, error) when is_binary(value) do
    trimmed = String.trim(value)
    len = String.length(trimmed)

    if len >= 1 and len <= 100 do
      {:ok, trimmed}
    else
      {:error, error}
    end
  end

  defp validate_name(_value, error), do: {:error, error}

  defp validate_email(value) when is_binary(value) do
    trimmed = String.trim(value)

    if byte_size(trimmed) <= 254 and Regex.match?(@email_regex, trimmed) do
      {:ok, trimmed}
    else
      {:error, :invalid_email}
    end
  end

  defp validate_email(_), do: {:error, :invalid_email}

  # Ecuador M2square gateway requires local phone numbers strictly under 10 digits (6..9 digits,
  # no country code "+593" and no leading "0").
  defp validate_phone("EC", value) when is_binary(value) do
    stripped = String.replace(value, ~r/\s+/, "")

    if Regex.match?(@ec_phone_regex, stripped) do
      {:ok, stripped}
    else
      {:error, :invalid_phone}
    end
  end

  defp validate_phone(_country_code, value) when is_binary(value) do
    trimmed = String.trim(value)
    digit_count = trimmed |> String.replace(~r/[^0-9]/, "") |> byte_size()

    if String.length(trimmed) in 6..20 and Regex.match?(@general_phone_regex, trimmed) and
         digit_count >= 6 do
      {:ok, trimmed}
    else
      {:error, :invalid_phone}
    end
  end

  defp validate_phone(_country_code, _value), do: {:error, :invalid_phone}

  defp validate_country_fields(%{code: "BR"} = cfg, params) do
    payment_type =
      case param(params, "payment_type") do
        nil -> "PIX"
        "" -> "PIX"
        val -> String.upcase(String.trim(val))
      end

    with :ok <- validate_payment_type(payment_type, cfg.payment_types),
         {:ok, cpf} <-
           validate_brazil_cpf(param(params, "doc_number") || param(params, "docNumber")) do
      extra =
        cfg
        |> Map.get(:extra_pay_fields, %{})
        |> stringify_map()

      doc_type = Map.get(cfg, :brazil_doc_type) || "PIX"

      fields =
        %{"docType" => doc_type, "docNumber" => cpf}
        |> Map.merge(extra)

      {:ok, payment_type, fields}
    end
  end

  defp validate_country_fields(%{code: "EC"} = cfg, params) do
    payment_type = normalize_upper(param(params, "payment_type"))
    beneficiary_type = normalize_upper(param(params, "beneficiary_type"))
    beneficiary_id = normalize_trimmed(param(params, "beneficiary_id"))

    with :ok <- validate_payment_type(payment_type, cfg.payment_types),
         :ok <- validate_beneficiary_type(beneficiary_type, cfg.id_types),
         :ok <- validate_ec_passport_payment_type(beneficiary_type, payment_type),
         {:ok, id} <- validate_ec_beneficiary_id(beneficiary_type, beneficiary_id) do
      {:ok, payment_type,
       %{
         "paymentType" => payment_type,
         "beneficiaryType" => beneficiary_type,
         "beneficiaryId" => id
       }}
    end
  end

  defp validate_country_fields(%{code: "PE"} = cfg, params) do
    payment_type = normalize_upper(param(params, "payment_type"))
    beneficiary_type = normalize_upper(param(params, "beneficiary_type"))
    beneficiary_id = normalize_trimmed(param(params, "beneficiary_id"))

    with :ok <- validate_payment_type(payment_type, cfg.payment_types),
         :ok <- validate_beneficiary_type(beneficiary_type, cfg.id_types),
         {:ok, id} <- validate_pe_beneficiary_id(beneficiary_type, beneficiary_id) do
      {:ok, payment_type,
       %{
         "paymentType" => payment_type,
         "beneficiaryType" => beneficiary_type,
         "beneficiaryId" => id
       }}
    end
  end

  defp validate_country_fields(%{code: "CL"} = cfg, params) do
    payment_type = normalize_upper(param(params, "payment_type"))
    beneficiary_type = normalize_upper(param(params, "beneficiary_type"))
    beneficiary_id = normalize_trimmed(param(params, "beneficiary_id"))

    with :ok <- validate_payment_type(payment_type, cfg.payment_types),
         :ok <- validate_beneficiary_type(beneficiary_type, cfg.id_types),
         {:ok, id} <- validate_cl_beneficiary_id(beneficiary_id) do
      fields = %{
        "paymentType" => payment_type,
        "beneficiaryType" => beneficiary_type,
        "beneficiaryId" => id
      }

      fields =
        case Map.get(cfg, :payment_method) do
          method when is_binary(method) and method != "" ->
            Map.put(fields, "paymentMethod", method)

          _ ->
            fields
        end

      {:ok, payment_type, fields}
    end
  end

  defp validate_country_fields(_cfg, _params), do: {:error, :unsupported_country}

  defp validate_payment_type(payment_type, allowed)
       when is_binary(payment_type) and is_list(allowed) do
    if payment_type in allowed, do: :ok, else: {:error, :unsupported_payment_type}
  end

  defp validate_payment_type(_, _), do: {:error, :unsupported_payment_type}

  defp validate_beneficiary_type(id_type, allowed)
       when is_binary(id_type) and is_list(allowed) do
    if id_type in allowed, do: :ok, else: {:error, :invalid_beneficiary_type}
  end

  defp validate_beneficiary_type(_, _), do: {:error, :invalid_beneficiary_type}

  defp validate_ec_passport_payment_type("PAS", payment_type) when payment_type != "NET_BANKING",
    do: {:error, :passport_requires_net_banking}

  defp validate_ec_passport_payment_type(_type, _payment_type), do: :ok

  defp validate_brazil_cpf(value) when is_binary(value) do
    digits = String.replace(value, ~r/[.\-\s\/]/, "")

    if Regex.match?(~r/\A[0-9]{11}\z/, digits) and not Regex.match?(~r/\A(\d)\1{10}\z/, digits) do
      {:ok, digits}
    else
      {:error, :invalid_doc_number}
    end
  end

  defp validate_brazil_cpf(_), do: {:error, :invalid_doc_number}

  defp validate_ec_beneficiary_id("CI", id) when is_binary(id) do
    if Regex.match?(~r/\A[0-9]{10}\z/, id), do: {:ok, id}, else: {:error, :invalid_beneficiary_id}
  end

  defp validate_ec_beneficiary_id("RUC", id) when is_binary(id) do
    if Regex.match?(~r/\A[0-9]{13}\z/, id), do: {:ok, id}, else: {:error, :invalid_beneficiary_id}
  end

  defp validate_ec_beneficiary_id("PAS", id) when is_binary(id) do
    if Regex.match?(~r/\A[A-Za-z0-9]{9,10}\z/, id),
      do: {:ok, id},
      else: {:error, :invalid_beneficiary_id}
  end

  defp validate_ec_beneficiary_id(_, _), do: {:error, :invalid_beneficiary_id}

  defp validate_pe_beneficiary_id("DNI", id) when is_binary(id) do
    if Regex.match?(~r/\A[0-9]{8}\z/, id), do: {:ok, id}, else: {:error, :invalid_beneficiary_id}
  end

  defp validate_pe_beneficiary_id("CE", id) when is_binary(id) do
    if Regex.match?(~r/\A[A-Za-z0-9]{8,12}\z/, id),
      do: {:ok, id},
      else: {:error, :invalid_beneficiary_id}
  end

  defp validate_pe_beneficiary_id("RUC", id) when is_binary(id) do
    if Regex.match?(~r/\A[0-9]{11}\z/, id), do: {:ok, id}, else: {:error, :invalid_beneficiary_id}
  end

  defp validate_pe_beneficiary_id("PAS", id) when is_binary(id) do
    if Regex.match?(~r/\A[A-Za-z0-9]{7,12}\z/, id),
      do: {:ok, id},
      else: {:error, :invalid_beneficiary_id}
  end

  defp validate_pe_beneficiary_id(_, _), do: {:error, :invalid_beneficiary_id}

  defp validate_cl_beneficiary_id(id) when is_binary(id) do
    if Regex.match?(~r/\A[A-Za-z0-9.\-]{5,20}\z/, id),
      do: {:ok, id},
      else: {:error, :invalid_beneficiary_id}
  end

  defp validate_cl_beneficiary_id(_), do: {:error, :invalid_beneficiary_id}

  defp param(params, key) when is_binary(key) do
    case Map.fetch(params, key) do
      {:ok, val} ->
        val

      :error ->
        Enum.find_value(params, fn
          {k, v} when is_atom(k) -> if Atom.to_string(k) == key, do: v
          _ -> nil
        end)
    end
  end

  defp normalize_upper(value) when is_binary(value), do: value |> String.trim() |> String.upcase()
  defp normalize_upper(_), do: nil

  defp normalize_trimmed(value) when is_binary(value), do: String.trim(value)
  defp normalize_trimmed(_), do: nil

  defp stringify_map(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp stringify_map(_), do: %{}
end
