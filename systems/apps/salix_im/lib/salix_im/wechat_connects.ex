defmodule SalixIM.WeChatConnects do
  @moduledoc "QR preparation and activation for the existing IM Connect lifecycle."
  alias SalixIM.{GroupDirectory, ProviderConnects, ProviderIdentity, WeChatAPI}
  alias SalixStore.{CasRecord, Ids, Keys}

  @ttl_seconds 300

  def create(tenant_id, group_id, owner_user_id, qr) do
    with {:ok, _} <- GroupDirectory.get_group(group_id, tenant_id),
         true <- nonblank?(qr["qrcode"]) and nonblank?(qr["qrcode_img_content"]) do
      id = Ids.new_connect_id()

      rec = %{
        "tenant_id" => tenant_id,
        "group_id" => group_id,
        "connect_id" => id,
        "provider" => "wechat",
        "managed_by" => "comma_product",
        "owner_user_id" => owner_user_id,
        "status" => "pending",
        "login_status" => "wait",
        "disabled_at" => now(),
        "qrcode" => qr["qrcode"],
        "qrcode_url" => qr["qrcode_img_content"],
        "login_base_url" => WeChatAPI.base_url(),
        "expires_at" => now() + @ttl_seconds,
        "created_at" => now(),
        "updated_at" => now()
      }

      CasRecord.create(Keys.ctl_im_connect(group_id, id), rec)
    else
      false -> {:error, :invalid_wechat_response}
      other -> other
    end
  end

  def fetch(_tenant_id, _group_id, nil), do: {:ok, nil}

  def fetch(tenant_id, group_id, id) do
    with {:ok, rec} <- CasRecord.get(Keys.ctl_im_connect(group_id, id)),
         true <-
           rec["tenant_id"] == tenant_id and rec["group_id"] == group_id and
             rec["provider"] == "wechat" and rec["managed_by"] == "comma_product" and
             is_nil(rec["deleted_at"]) do
      {:ok, rec}
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  def retire(tenant_id, group_id, id) do
    with {:ok, _} <- GroupDirectory.get_group(group_id, tenant_id) do
      case ProviderConnects.delete_im_connect(tenant_id, group_id, id) do
        :ok -> finish_retirement(tenant_id, group_id, id, false)
        {:error, :not_found} -> finish_retirement(tenant_id, group_id, id, true)
        other -> other
      end
    end
  end

  defp finish_retirement(tenant_id, group_id, id, retry_release?) do
    key = Keys.ctl_im_connect(group_id, id)

    case CasRecord.get(key) do
      {:ok, rec} ->
        with true <-
               rec["deleted_at"] != nil and rec["tenant_id"] == tenant_id and
                 rec["group_id"] == group_id and rec["provider"] == "wechat" and
                 rec["managed_by"] == "comma_product",
             :ok <- if(retry_release?, do: ProviderIdentity.release(rec), else: :ok) do
          # Pending/prepared attempts never admitted messages. Cancellation
          # discards only this temporary QR state; active connection history stays.
          if rec["status"] in ["pending", "prepared"], do: SalixStore.S3.delete(key), else: :ok
        else
          false -> {:error, :not_found}
          other -> other
        end

      {:error, :not_found} ->
        :ok

      other ->
        other
    end
  end

  def public(nil), do: nil

  def public(rec) do
    rec
    |> Map.take(~w(connect_id status login_status wechat_id bot_user_id connected_at expires_at))
    |> Map.put("connection_active", rec["status"] == "connected" and is_nil(rec["disabled_at"]))
    |> Map.put("qrcode_url", if(rec["status"] == "pending", do: rec["qrcode_url"]))
    |> Map.update("login_status", nil, fn status ->
      if rec["status"] == "pending" and rec["expires_at"] <= now(), do: "expired", else: status
    end)
  end

  def poll(rec, verify_code \\ nil) do
    cond do
      rec["status"] in ["prepared", "connected"] ->
        {:ok, rec}

      rec["status"] != "pending" or rec["expires_at"] <= now() ->
        {:error, :wechat_login_expired}

      not valid_code?(verify_code) ->
        {:error, :invalid_wechat_verification_code}

      true ->
        with {:ok, response} <-
               WeChatAPI.poll_login(rec["login_base_url"], rec["qrcode"], verify_code),
             {:ok, fields} <- response_fields(response) do
          update_pending(rec, fields)
        end
    end
  end

  def activate(tenant_id, group_id, id) do
    with {:ok, rec} <- fetch(tenant_id, group_id, id),
         true <- rec["status"] in ["prepared", "connected"],
         :ok <- ProviderIdentity.reserve({"wechat", rec["bot_user_id"]}, tenant_id, group_id, id) do
      result =
        CasRecord.update(
          Keys.ctl_im_connect(group_id, id),
          fn current ->
            if current["deleted_at"] || current["status"] not in ["prepared", "connected"] do
              {:error, :invalid_wechat_connection_attempt}
            else
              current
              |> Map.delete("disabled_at")
              |> Map.put("status", "connected")
              |> Map.put("updated_at", now())
            end
          end,
          create: false
        )

      if match?({:error, _}, result) do
        case CasRecord.get(Keys.ctl_im_connect(group_id, id)) do
          {:ok, %{"deleted_at" => deleted}} when not is_nil(deleted) ->
            ProviderIdentity.release(rec)

          {:error, :not_found} ->
            ProviderIdentity.release(rec)

          _ ->
            :ok
        end
      end

      result
    else
      false -> {:error, :invalid_wechat_connection_attempt}
      other -> other
    end
  end

  defp update_pending(rec, fields) do
    CasRecord.update(
      Keys.ctl_im_connect(rec["group_id"], rec["connect_id"]),
      fn current ->
        cond do
          current["deleted_at"] || current["expires_at"] <= now() ->
            {:error, :invalid_wechat_connection_attempt}

          current["status"] in ["prepared", "connected"] ->
            {:unchanged, current}

          current["status"] == "pending" and current["qrcode"] == rec["qrcode"] ->
            current |> Map.merge(fields) |> Map.put("updated_at", now())

          true ->
            {:error, :invalid_wechat_connection_attempt}
        end
      end,
      create: false
    )
  end

  defp response_fields(%{"status" => "confirmed"} = response) do
    with true <- Enum.all?(~w(bot_token ilink_bot_id ilink_user_id), &nonblank?(response[&1])),
         {:ok, base} <- WeChatAPI.validate_origin(response["baseurl"] || WeChatAPI.base_url()) do
      {:ok,
       %{
         "status" => "prepared",
         "login_status" => "confirmed",
         "token" => response["bot_token"],
         "bot_user_id" => response["ilink_bot_id"],
         "wechat_id" => response["ilink_user_id"],
         "base_url" => base,
         "updates_buf" => "",
         "latest_context_token" => "",
         "connected_at" => now(),
         "qrcode_url" => nil
       }}
    else
      false -> {:error, :invalid_wechat_response}
      other -> other
    end
  end

  defp response_fields(%{"status" => "scaned_but_redirect", "redirect_host" => host})
       when is_binary(host) do
    with {:ok, base} <- WeChatAPI.validate_origin("https://" <> host),
         do: {:ok, %{"login_base_url" => base, "login_status" => "scaned"}}
  end

  defp response_fields(%{"status" => status})
       when status in ~w(wait scaned need_verifycode expired verify_code_blocked binded_redirect),
       do: {:ok, %{"login_status" => status}}

  defp response_fields(_), do: {:error, :invalid_wechat_response}

  defp valid_code?(nil), do: true
  defp valid_code?(value) when is_binary(value), do: Regex.match?(~r/\A[0-9]{1,16}\z/, value)
  defp valid_code?(_), do: false

  defp nonblank?(value),
    do: is_binary(value) and String.trim(value) != "" and byte_size(value) <= 4096

  defp now, do: System.system_time(:second)
end
