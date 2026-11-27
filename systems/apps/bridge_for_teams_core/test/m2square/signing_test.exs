defmodule BridgeForTeams.M2square.SigningTest do
  use SystemsClock.Case, async: true

  alias BridgeForTeams.M2square.Signing

  describe "sign_request/7" do
    test "matches official API signing specification (p_7523662m0.md) SHA512 concatenation order" do
      # Exact payload and parameters from M2square API signing doc (p_7523662m0.md).
      mch_id = "1416010331032883200"
      service_name = "api.pay"
      method = "pay"
      timestamp = "1631671670"
      sign_type = "SHA512"
      secret_key = "TU7FZ56=="

      raw_json =
        ~s({"amount":"5.00","callbackUrl":"http://127.0.0.1:8082/callback","redirectUrl":"http://www.baidu.com","currency":"BRL","dynamic":"1","email":"muazpe@gmail.com","firstname":"Murilo Azeredo Pereira","lastname":"your lasttname","mchOrderId":"1232434323233463411fv34","phone":"+5511967164793","docNumber":"14868845802","docType":"CPF","productinfo":"your pro simple desc"})

      expected =
        "796b4b75f2c72c0aad41bab93f249bb5a9c9ec32b8aea6e532ac8c60620d6e2b88e86ed7b27b790f18392f31e1daefa88eb3f19d36d4779d7b7e8e92be683706"

      sign =
        Signing.sign_request(
          mch_id,
          service_name,
          method,
          timestamp,
          sign_type,
          raw_json,
          secret_key
        )

      assert sign == expected
      assert byte_size(sign) == 128
      assert sign == String.downcase(sign)

      # Integer timestamp produces the identical digest.
      assert Signing.sign_request(
               mch_id,
               service_name,
               method,
               1_631_671_670,
               sign_type,
               raw_json,
               secret_key
             ) == expected

      # Any byte-level change in raw_json (e.g. extra space) changes the signature.
      refute Signing.sign_request(
               mch_id,
               service_name,
               method,
               timestamp,
               sign_type,
               raw_json <> " ",
               secret_key
             ) == expected
    end
  end

  describe "verify_webhook/3" do
    test "matches official webhook verification specification (p_7523664m0.md)" do
      # Exact webhook payload and key from M2square webhook doc (p_7523664m0.md).
      raw_body =
        ~s({"realAmount":"166840.0","orderType":"PAYOUT","bankId":"9jZVPfXobPGXXnt","amount":"166840.0","createTime":"20250812091550","orderId":"202508121955196515039150080","payMethod":"NET_BANKING","orderStatus":"SUCCESS","mchOrderId":"W20250812091450181OT","failMessage":"fix order to SUCCESS"})

      secret_key = "Dkfldkfl=="

      expected_sign =
        :crypto.hash(:sha512, raw_body <> secret_key)
        |> Base.encode16(case: :lower)

      assert :ok == Signing.verify_webhook(raw_body, expected_sign, secret_key)
      assert :ok == Signing.verify_webhook(raw_body, String.upcase(expected_sign), secret_key)
      assert :ok == Signing.verify_webhook(raw_body, "  #{expected_sign}  ", secret_key)

      # Tampered body or wrong key or wrong signature fails closed.
      assert {:error, :invalid_signature} ==
               Signing.verify_webhook(raw_body <> " ", expected_sign, secret_key)

      assert {:error, :invalid_signature} ==
               Signing.verify_webhook(raw_body, expected_sign, "wrong-key")

      assert {:error, :invalid_signature} ==
               Signing.verify_webhook(raw_body, "deadbeef", secret_key)

      assert {:error, :invalid_signature} ==
               Signing.verify_webhook(raw_body, nil, secret_key)
    end

    test "returns :webhook_not_configured when secret_key is missing or empty" do
      assert {:error, :webhook_not_configured} == Signing.verify_webhook("{}", "abc", nil)
      assert {:error, :webhook_not_configured} == Signing.verify_webhook("{}", "abc", "")
    end
  end
end
