defmodule SalixSignal.Profiles do
  @moduledoc """
  The account profile over the version 1 REST profile API (CRS-08 sections
  5 to 7).

  `set_profile/3` encrypts the name and the other fields with the profile
  key and sends `PUT /v1/profile` over the authenticated chat socket. For a
  new avatar the service answers with an S3 POST form, and the encrypted
  avatar is uploaded to CDN 0.

  `get_profile/3` reads another account's profile over the given chat
  socket. With the target's profile key and ACI it reads the versioned
  profile and decrypts its fields. With the target's access key it sends
  `Unidentified-Access-Key`; use the unauthenticated chat socket for that,
  so the service does not learn who is asking.

  The profile key commitment and the expiring profile key credential come
  from the group credential code (`SalixSignalProto.Group.ProfileKey` and
  `SalixSignalProto.Group.ProfileKeyCredential`, CRS-09a sections 8.5 and 14),
  which owns them (owner decision on clean question C6-1).

  An account that uses this API must not declare the `profiles_v2`
  capability; the service answers such accounts with 412 (CRS-08 section
  5.3).
  """

  alias SalixSignal.Service.{Chat, Endpoints, Http, Response}
  alias SalixSignalProto.{Address, Profile}
  alias SalixSignalProto.Group.{ProfileKey, ProfileKeyCredential, ServerParams}

  # CRS-08 section 5.4: the avatar upload policy allows 1 to 10 MiB.
  @max_encrypted_avatar_bytes 10_485_760
  @avatar_overhead 28
  @form_fields [
    {"key", "key"},
    {"x-amz-credential", "credential"},
    {"acl", "acl"},
    {"x-amz-algorithm", "algorithm"},
    {"x-amz-date", "date"},
    {"policy", "policy"},
    {"x-amz-signature", "signature"}
  ]

  @type profile :: %{
          identity_key: binary() | nil,
          unidentified_access: binary() | nil,
          unrestricted_unidentified_access: boolean(),
          capabilities: %{String.t() => boolean()},
          badges: list(),
          service_id: String.t() | nil,
          name: {String.t(), String.t() | nil} | nil,
          about: String.t() | nil,
          about_emoji: String.t() | nil,
          avatar: String.t() | nil,
          phone_number_sharing: boolean() | nil,
          credential: binary() | nil,
          credential_expiration: non_neg_integer() | nil,
          key_mismatch: boolean()
        }

  @doc """
  Sets this account's profile.

  `fields`: `:profile_key`, `:aci` (the account's ACI string), `:given_name`,
  and optionally `:family_name`, `:about`, `:about_emoji`,
  `:phone_number_sharing` (default false), `:avatar` (`:keep`, `:clear` or
  `{:new, image_bytes}`, default `:clear`) and `:badge_ids` (omitted keeps
  the current badges).

  Options: `:environment`, `:http` (options for the CDN request),
  `:cdn0_url` (for tests) and `:timeout`.

  Returns the profile version and, after a new avatar, its CDN path. After
  a profile key rotation, `:keep` gives no avatar: upload it again
  (CRS-08 section 5.2).
  """
  @spec set_profile(GenServer.server(), map(), keyword()) ::
          {:ok, %{version: String.t(), avatar: String.t() | nil}} | {:error, term()}
  def set_profile(chat, %{} = fields, opts \\ []) do
    with {:ok, body, version} <- profile_body(fields),
         {:ok, response} <-
           Chat.request(chat, "PUT", "/v1/profile", Keyword.put(opts_timeout(opts), :json, body)) do
      case {response.status, fields[:avatar]} do
        {200, {:new, image}} -> upload_avatar(response, fields.profile_key, image, version, opts)
        {200, _} -> {:ok, %{version: version, avatar: nil}}
        {400, _} -> {:error, :bad_request}
        {403, _} -> {:error, :payments_not_allowed}
        {412, _} -> {:error, :profiles_v2_required}
        {422, _} -> {:error, :invalid_profile}
        {_, _} -> {:error, Response.outcome(response)}
      end
    end
  end

  @doc """
  The JSON body of `PUT /v1/profile` and the profile version, with fresh
  random nonces (CRS-08 section 5.1). The commitment is
  `SalixSignalProto.Group.ProfileKey.commitment/2` of the profile key and the
  ACI (CRS-08 section 3.4).
  """
  @spec profile_body(map()) :: {:ok, map(), String.t()} | {:error, term()}
  def profile_body(%{profile_key: <<_::binary-size(32)>> = key, aci: aci} = fields) do
    avatar = Map.get(fields, :avatar, :clear)

    with {:ok, {:aci, aci_uuid}} <- Address.parse_service_id(aci),
         {:ok, name} <- Profile.encrypt_name(key, fields[:given_name] || "", fields[:family_name]),
         {:ok, about} <- optional_text(&Profile.encrypt_about/2, key, fields[:about]),
         {:ok, emoji} <- optional_text(&Profile.encrypt_about_emoji/2, key, fields[:about_emoji]),
         :ok <- check_avatar(avatar) do
      version = Profile.version(key, aci_uuid)
      commitment = ProfileKey.commitment(key, aci_uuid)
      sharing = Profile.encrypt_phone_number_sharing(key, fields[:phone_number_sharing] == true)

      body =
        %{
          "version" => version,
          "commitment" => Base.encode64(commitment),
          "name" => Base.encode64(name),
          "about" => about && Base.encode64(about),
          "aboutEmoji" => emoji && Base.encode64(emoji),
          "paymentAddress" => nil,
          "phoneNumberSharing" => Base.encode64(sharing),
          "avatar" => avatar != :clear,
          "sameAvatar" => avatar == :keep
        }
        |> put_badges(fields[:badge_ids])

      {:ok, body, version}
    else
      {:ok, {:pni, _}} -> {:error, :invalid_aci}
      :error -> {:error, :invalid_aci}
      {:error, _} = error -> error
    end
  end

  def profile_body(_fields), do: {:error, :invalid_profile_key}

  @doc """
  Reads a profile (CRS-08 section 6).

  `service_id` is an ACI string or a `PNI:` service id string. Options:

    * `:profile_key`: the target's profile key; with an ACI this reads the
      versioned profile and decrypts its fields.
    * `:credential`: `%{server_params: params, now: unix_seconds}` asks for
      an expiring profile key credential (CRS-08 section 7); needs
      `:profile_key` and an ACI. `params` are the group server's public
      params (673 bytes or `SalixSignalProto.Group.ServerParams.Public`).
      The request and the check of the response are the group credential
      code's (`SalixSignalProto.Group.ProfileKeyCredential`). The result
      carries the 153-byte credential and its expiration, or nil when the
      service returned none. A response that fails the check gives
      `{:error, :credential_verification_failed}`. `:credential_randomness`
      (32 bytes) is for tests.
    * `:access_key`: the target's 16-byte access key, sent as
      `Unidentified-Access-Key` (not valid for a PNI).
    * `:group_send_token`: sent as `Group-Send-Token`; unversioned only.
    * `:accept_language` and `:timeout`.
  """
  @spec get_profile(GenServer.server(), String.t(), keyword()) ::
          {:ok, profile()} | {:error, term()}
  def get_profile(chat, service_id, opts \\ []) when is_binary(service_id) do
    with {:ok, parsed} <- parse_service_id(service_id),
         {:ok, credential} <- credential_request(parsed, opts),
         {:ok, path} <- profile_path(service_id, parsed, credential, opts),
         {:ok, headers} <- profile_headers(parsed, opts),
         {:ok, response} <-
           Chat.request(chat, "GET", path, [headers: headers] ++ opts_timeout(opts)) do
      case response.status do
        200 -> parse_profile(response, opts[:profile_key], credential)
        400 -> {:error, :bad_request}
        401 -> {:error, :unauthorized}
        404 -> {:error, :not_found}
        _ -> {:error, Response.outcome(response)}
      end
    end
  end

  @doc """
  Downloads and decrypts an avatar from its CDN 0 path (CRS-08 section 5.5).
  The path is the `avatar` value of a profile and starts with `profiles/`.

  Options: `:environment`, `:http` and `:cdn0_url` (for tests).
  """
  @spec download_avatar(String.t(), Profile.profile_key(), keyword()) ::
          {:ok, binary()} | {:error, term()}
  def download_avatar(path, profile_key, opts \\ []) when is_binary(path) do
    if Regex.match?(~r/\Aprofiles\/[A-Za-z0-9_=-]{1,128}\z/, path) do
      url = cdn0_url(opts) <> "/" <> path
      http_opts = [max_body_bytes: @max_encrypted_avatar_bytes] ++ Keyword.get(opts, :http, [])

      case Http.request(:get, url, http_opts) do
        {:ok, %Response{status: 200, body: body}} -> Profile.decrypt(profile_key, body)
        {:ok, %Response{status: 404}} -> {:error, :not_found}
        {:ok, %Response{status: status}} -> {:error, {:http_status, status}}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :invalid_avatar_path}
    end
  end

  # --- Set -----------------------------------------------------------------

  defp optional_text(_encrypt, _key, value) when value in [nil, ""], do: {:ok, nil}
  defp optional_text(encrypt, key, value), do: encrypt.(key, value)

  defp check_avatar(avatar) when avatar in [:keep, :clear], do: :ok

  defp check_avatar({:new, image}) when is_binary(image) and image != "" do
    if byte_size(image) + @avatar_overhead <= @max_encrypted_avatar_bytes,
      do: :ok,
      else: {:error, :avatar_too_large}
  end

  defp check_avatar(_), do: {:error, :invalid_avatar}

  defp put_badges(body, nil), do: body

  defp put_badges(body, ids) when is_list(ids) do
    if Enum.all?(ids, &is_binary/1), do: Map.put(body, "badgeIds", ids), else: body
  end

  # CRS-08 sections 5.4 and 5.5: the S3 POST form and the multipart upload.
  defp upload_avatar(response, profile_key, image, version, opts) do
    with {:ok, %{} = form} <- Response.json(response),
         {:ok, parts} <- form_parts(form) do
      encrypted = Profile.encrypt(profile_key, image)
      boundary = "salix-" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
      body = multipart(boundary, parts, encrypted)

      http_opts =
        [
          headers: [{"content-type", "multipart/form-data; boundary=" <> boundary}],
          body: body
        ] ++ Keyword.get(opts, :http, [])

      case Http.request(:post, cdn0_url(opts) <> "/", http_opts) do
        {:ok, %Response{status: status}} when status in 200..299 ->
          {:ok, %{version: version, avatar: form["key"]}}

        {:ok, %Response{status: status}} ->
          {:error, {:avatar_upload_failed, status}}

        {:error, reason} ->
          {:error, {:avatar_upload_failed, reason}}
      end
    else
      _ -> {:error, :invalid_avatar_form}
    end
  end

  defp form_parts(form) do
    parts = for {part, field} <- @form_fields, do: {part, form[field]}

    if Enum.all?(parts, fn {_part, value} ->
         is_binary(value) and not String.contains?(value, ["\r", "\n"])
       end),
       do: {:ok, parts ++ [{"Content-Type", "application/octet-stream"}]},
       else: :error
  end

  defp multipart(boundary, parts, file) do
    fields =
      for {name, value} <- parts do
        [
          "--",
          boundary,
          "\r\n",
          ~s(Content-Disposition: form-data; name="),
          name,
          ~s("\r\n\r\n),
          value,
          "\r\n"
        ]
      end

    file_part = [
      "--",
      boundary,
      "\r\n",
      ~s(Content-Disposition: form-data; name="file"\r\n),
      "Content-Type: application/octet-stream\r\n\r\n",
      file,
      "\r\n--",
      boundary,
      "--\r\n"
    ]

    IO.iodata_to_binary([fields, file_part])
  end

  # --- Get -----------------------------------------------------------------

  defp parse_service_id(service_id) do
    case Address.parse_service_id(service_id) do
      {:ok, parsed} -> {:ok, parsed}
      :error -> {:error, :invalid_service_id}
    end
  end

  # The expiring profile key credential request (CRS-08 section 7, steps 1
  # and 2), made by the group credential code.
  defp credential_request(parsed, opts) do
    case {opts[:credential], parsed, opts[:profile_key]} do
      {nil, _, _} ->
        {:ok, nil}

      {%{server_params: params, now: now}, {:aci, uuid}, <<_::binary-size(32)>> = key}
      when is_integer(now) ->
        with {:ok, server} <- server_params(params) do
          randomness = opts[:credential_randomness] || :crypto.strong_rand_bytes(32)
          {context, request} = ProfileKeyCredential.request(uuid, key, randomness)
          {:ok, %{server: server, context: context, request: request, now: now}}
        end

      _ ->
        {:error, :invalid_profile_request}
    end
  end

  defp server_params(%ServerParams.Public{} = params), do: {:ok, params}

  defp server_params(bytes) when is_binary(bytes) do
    case ServerParams.decode_public(bytes) do
      {:ok, params} -> {:ok, params}
      {:error, :invalid} -> {:error, :invalid_server_params}
    end
  end

  defp server_params(_params), do: {:error, :invalid_server_params}

  defp profile_path(service_id, parsed, credential, opts) do
    case {parsed, opts[:profile_key], credential} do
      {_, nil, nil} ->
        {:ok, "/v1/profile/" <> service_id}

      {{:aci, uuid}, <<_::binary-size(32)>> = key, nil} ->
        {:ok, "/v1/profile/#{service_id}/#{Profile.version(key, uuid)}"}

      {{:aci, uuid}, <<_::binary-size(32)>> = key, %{request: request}} ->
        {:ok,
         "/v1/profile/#{service_id}/#{Profile.version(key, uuid)}/" <>
           Base.encode16(request, case: :lower) <> "?credentialType=expiringProfileKey"}

      {{:pni, _}, _, _} ->
        {:error, :versioned_profile_needs_aci}

      _ ->
        {:error, :invalid_profile_request}
    end
  end

  defp profile_headers(parsed, opts) do
    language = if lang = opts[:accept_language], do: [{"accept-language", lang}], else: []

    case {opts[:access_key], opts[:group_send_token], parsed, opts[:profile_key]} do
      {nil, nil, _, _} ->
        {:ok, language}

      {<<_::binary-size(16)>> = key, nil, {:aci, _}, _} ->
        {:ok, language ++ [{"unidentified-access-key", Base.encode64(key)}]}

      # A group send token is valid for the unversioned endpoint only.
      {nil, token, _, nil} when is_binary(token) ->
        {:ok, language ++ [{"group-send-token", Base.encode64(token)}]}

      _ ->
        {:error, :invalid_access}
    end
  end

  defp parse_profile(response, profile_key, credential) do
    case Response.json(response) do
      {:ok, %{} = json} ->
        json |> profile_from_json(profile_key) |> receive_credential(credential)

      _ ->
        {:error, :invalid_response}
    end
  end

  # CRS-08 section 7, step 5: the group credential code checks the response
  # against the request context and the local clock.
  defp receive_credential(profile, nil), do: {:ok, %{profile | credential: nil}}
  defp receive_credential(%{credential: nil} = profile, _credential), do: {:ok, profile}

  defp receive_credential(profile, credential) do
    case ProfileKeyCredential.receive(
           credential.server,
           credential.context,
           profile.credential,
           credential.now
         ) do
      {:ok, expiring, expiration} ->
        {:ok, %{profile | credential: expiring, credential_expiration: expiration}}

      {:error, :invalid} ->
        {:error, :credential_verification_failed}
    end
  end

  defp profile_from_json(json, profile_key) do
    base = %{
      identity_key: base64(json["identityKey"]),
      unidentified_access: base64(json["unidentifiedAccess"]),
      unrestricted_unidentified_access: json["unrestrictedUnidentifiedAccess"] == true,
      capabilities: capabilities(json["capabilities"]),
      badges: if(is_list(json["badges"]), do: json["badges"], else: []),
      service_id: if(is_binary(json["uuid"]), do: json["uuid"]),
      avatar: avatar_path(json["avatar"]),
      credential: base64(json["credential"]),
      credential_expiration: nil,
      name: nil,
      about: nil,
      about_emoji: nil,
      phone_number_sharing: nil,
      key_mismatch: false
    }

    if is_binary(profile_key), do: decrypt_fields(base, json, profile_key), else: base
  end

  # A field that fails to decrypt is left out; a tag failure usually means
  # an outdated profile key (CRS-08 section 4.1), which `key_mismatch`
  # reports.
  defp decrypt_fields(profile, json, key) do
    [
      {:name, "name", &Profile.decrypt_name/2},
      {:about, "about", &Profile.decrypt_text/2},
      {:about_emoji, "aboutEmoji", &Profile.decrypt_text/2},
      {:phone_number_sharing, "phoneNumberSharing", &Profile.decrypt_phone_number_sharing/2}
    ]
    |> Enum.reduce(profile, fn {field, json_field, decrypt}, profile ->
      case base64(json[json_field]) do
        nil ->
          profile

        encrypted ->
          case decrypt.(key, encrypted) do
            {:ok, value} -> Map.put(profile, field, value)
            {:error, :invalid} -> %{profile | key_mismatch: true}
            {:error, _} -> profile
          end
      end
    end)
  end

  defp capabilities(%{} = map),
    do: for({k, v} <- map, is_binary(k) and is_boolean(v), into: %{}, do: {k, v})

  defp capabilities(_), do: %{}

  defp avatar_path(path) when is_binary(path) and path != "", do: path
  defp avatar_path(_), do: nil

  defp base64(value) when is_binary(value) and value != "" do
    case Base.decode64(value) do
      {:ok, bytes} -> bytes
      :error -> nil
    end
  end

  defp base64(_), do: nil

  defp cdn0_url(opts) do
    opts[:cdn0_url] ||
      "https://" <> Endpoints.host(Keyword.get(opts, :environment, :production), :cdn0)
  end

  defp opts_timeout(opts), do: Keyword.take(opts, [:timeout])
end
