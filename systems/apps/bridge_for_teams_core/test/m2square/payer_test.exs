defmodule BridgeForTeams.M2square.PayerTest do
  use SystemsClock.Case, async: true

  alias BridgeForTeams.M2square.Config
  alias BridgeForTeams.M2square.Payer

  defp country!(code) do
    {:ok, cfg} = Config.country(code)
    cfg
  end

  defp base_params(overrides) do
    Map.merge(
      %{
        "firstname" => "Maria",
        "lastname" => "Silva",
        "email" => "maria@example.com",
        "phone" => "+5511967164793"
      },
      overrides
    )
  end

  describe "Brazil (BR)" do
    test "accepts formatted 11-digit CPF and merges brazil_doc_type and extra_pay_fields" do
      br =
        country!("BR")
        |> Map.put(:brazil_doc_type, "CPF")
        |> Map.put(:extra_pay_fields, %{"pixCheck" => "true"})

      params = base_params(%{"payment_type" => "PIX", "doc_number" => "148.688.458-02"})

      assert {:ok, %{payment_type: "PIX", gateway_fields: fields}} =
               Payer.validate_and_build_pay_fields(br, params)

      assert fields["docType"] == "CPF"
      assert fields["docNumber"] == "14868845802"
      assert fields["pixCheck"] == "true"
      assert fields["firstname"] == "Maria"
      assert fields["lastname"] == "Silva"
    end

    test "rejects invalid CPF and unsupported payment types" do
      br = country!("BR")

      assert {:error, :invalid_doc_number} =
               Payer.validate_and_build_pay_fields(br, base_params(%{"doc_number" => "12345"}))

      assert {:error, :invalid_doc_number} =
               Payer.validate_and_build_pay_fields(
                 br,
                 base_params(%{"doc_number" => "00000000000"})
               )

      assert {:error, :unsupported_payment_type} =
               Payer.validate_and_build_pay_fields(
                 br,
                 base_params(%{"payment_type" => "CASH", "doc_number" => "14868845802"})
               )
    end
  end

  describe "Ecuador (EC)" do
    test "validates CI, RUC, PAS and strict 6..9 digit local phone" do
      ec = country!("EC")

      assert {:ok, %{payment_type: "NET_BANKING", gateway_fields: fields}} =
               Payer.validate_and_build_pay_fields(
                 ec,
                 base_params(%{
                   "phone" => "987654321",
                   "payment_type" => "NET_BANKING",
                   "beneficiary_type" => "CI",
                   "beneficiary_id" => "1712345678"
                 })
               )

      assert fields["phone"] == "987654321"
      assert fields["beneficiaryType"] == "CI"
      assert fields["beneficiaryId"] == "1712345678"

      assert {:ok, _} =
               Payer.validate_and_build_pay_fields(
                 ec,
                 base_params(%{
                   "phone" => "98765432",
                   "payment_type" => "NET_BANKING",
                   "beneficiary_type" => "RUC",
                   "beneficiary_id" => "1712345678001"
                 })
               )

      assert {:ok, _} =
               Payer.validate_and_build_pay_fields(
                 ec,
                 base_params(%{
                   "phone" => "987654",
                   "payment_type" => "NET_BANKING",
                   "beneficiary_type" => "PAS",
                   "beneficiary_id" => "AB1234567"
                 })
               )
    end

    test "rejects EC phone >= 10 digits, +593 prefix, leading 0, or < 6 digits" do
      ec = country!("EC")

      for bad_phone <- ["1234567890", "0987654321", "+593987654321", "01234567", "12345"] do
        assert {:error, :invalid_phone} =
                 Payer.validate_and_build_pay_fields(
                   ec,
                   base_params(%{
                     "phone" => bad_phone,
                     "payment_type" => "NET_BANKING",
                     "beneficiary_type" => "CI",
                     "beneficiary_id" => "1712345678"
                   })
                 )
      end
    end

    test "rejects PAS with CASH even when CASH is enabled in config" do
      ec = country!("EC") |> Map.put(:payment_types, ["NET_BANKING", "CASH"])

      assert {:error, :passport_requires_net_banking} =
               Payer.validate_and_build_pay_fields(
                 ec,
                 base_params(%{
                   "phone" => "987654321",
                   "payment_type" => "CASH",
                   "beneficiary_type" => "PAS",
                   "beneficiary_id" => "AB1234567"
                 })
               )
    end
  end

  describe "Peru (PE) and Chile (CL)" do
    test "validates PE DNI/CE/RUC/PAS and rejects wrong lengths" do
      pe = country!("PE")

      assert {:ok, %{payment_type: "TD", gateway_fields: fields}} =
               Payer.validate_and_build_pay_fields(
                 pe,
                 base_params(%{
                   "phone" => "+51987654321",
                   "payment_type" => "TD",
                   "beneficiary_type" => "DNI",
                   "beneficiary_id" => "12345678"
                 })
               )

      assert fields["paymentType"] == "TD"
      assert fields["beneficiaryType"] == "DNI"

      assert {:error, :invalid_beneficiary_id} =
               Payer.validate_and_build_pay_fields(
                 pe,
                 base_params(%{
                   "phone" => "+51987654321",
                   "payment_type" => "TC",
                   "beneficiary_type" => "DNI",
                   "beneficiary_id" => "1234567"
                 })
               )
    end

    test "validates CL RUT/PP and includes paymentMethod" do
      cl = country!("CL")

      assert {:ok, %{payment_type: "NET_BANKING", gateway_fields: fields}} =
               Payer.validate_and_build_pay_fields(
                 cl,
                 base_params(%{
                   "phone" => "+56912345678",
                   "payment_type" => "NET_BANKING",
                   "beneficiary_type" => "RUT",
                   "beneficiary_id" => "12345678-9"
                 })
               )

      assert fields["paymentMethod"] == "CHECKOUT_URL"
      assert fields["beneficiaryType"] == "RUT"
    end

    test "rejects invalid common fields" do
      br = country!("BR")

      assert {:error, :invalid_firstname} =
               Payer.validate_and_build_pay_fields(br, base_params(%{"firstname" => "   "}))

      assert {:error, :invalid_lastname} =
               Payer.validate_and_build_pay_fields(br, base_params(%{"lastname" => ""}))

      assert {:error, :invalid_email} =
               Payer.validate_and_build_pay_fields(br, base_params(%{"email" => "not-an-email"}))
    end
  end
end
