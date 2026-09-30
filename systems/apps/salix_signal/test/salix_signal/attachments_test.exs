defmodule SalixSignal.AttachmentsTest do
  # Attachment upload and download (CRS-10 sections 3 to 6 and 9) against
  # the fake chat service and a fake CDN written from CRS-10.
  use ExUnit.Case, async: true

  # Upper bounds on a loaded machine, not expectations: a TLS connect and
  # upgrade (the chat client's own connect timeout is 10 s), and any other
  # wait for a message or a task.
  @connect_ms 30_000
  @wait_ms 30_000

  alias SalixSignal.Attachments
  alias SalixSignal.Service.{Chat, Credentials}
  alias SalixSignal.Test.{FakeCdn, FakeChat}
  alias SalixSignalProto.Attachment
  alias SalixSignalProto.Attachment.Pointer
  alias SalixSignalProto.Service.Frame

  @aci "00000000-0000-4000-8000-000000000063"

  setup_all do
    %{chain: FakeChat.chain()}
  end

  setup %{chain: chain} do
    {:ok, upgrades} = Agent.start_link(fn -> [] end)

    chat_server =
      start_supervised!({Bandit, FakeChat.bandit_options(self(), chain, upgrades)}, id: :chat)

    cdn = start_supervised!({FakeCdn, self()})
    cdn_server = start_supervised!({Bandit, FakeCdn.bandit_options(cdn, chain)}, id: :cdn)

    chat =
      start_supervised!(
        {Chat,
         owner: self(),
         host: "localhost",
         port: FakeChat.port(chat_server),
         roots: [chain.root],
         credentials: Credentials.device(@aci, 1, "pw")}
      )

    assert_receive {:signal_chat, ^chat, {:connected, _}}, @connect_ms
    assert_receive {:fake_chat, :connected, socket}, @connect_ms

    cdn_url = "https://localhost:#{FakeChat.port(cdn_server)}"

    %{
      chat: chat,
      socket: socket,
      cdn: cdn,
      cdn_url: cdn_url,
      http: [trust: :signal, roots: [chain.root]],
      base_urls: %{0 => cdn_url, 2 => cdn_url, 3 => cdn_url}
    }
  end

  defp answer_form(socket, status, body, headers \\ []) do
    assert_receive {:fake_chat, :frame, ^socket,
                    %Frame.Request{
                      verb: "GET",
                      path: "/v4/attachments/form/upload?uploadLength=" <> n
                    } =
                      request},
                   @wait_ms

    response = %Frame.Response{
      id: request.id,
      status: status,
      body: body && Jason.encode!(body),
      headers: headers
    }

    send(socket, {:send, Frame.encode_response(response)})
    String.to_integer(n)
  end

  defp tus_form(ctx, key) do
    %{
      "cdn" => 3,
      "key" => key,
      "headers" => %{
        "Authorization" => "Bearer test-token",
        "Upload-Metadata" => "filename " <> Base.encode64(key)
      },
      "signedUploadLocation" => ctx.cdn_url <> "/tus/attachments"
    }
  end

  defp cdn2_form(ctx, key, upload_length) do
    %{
      "cdn" => 2,
      "key" => key,
      "headers" => %{
        "x-goog-content-length-range" => "1,#{upload_length}",
        "x-goog-resumable" => "start"
      },
      "signedUploadLocation" => ctx.cdn_url <> "/cdn2/start?key=#{key}"
    }
  end

  defp upload(ctx, plaintext, opts) do
    Task.async(fn ->
      Attachments.upload(ctx.chat, plaintext, Keyword.merge([http: ctx.http], opts))
    end)
  end

  defp download(ctx, pointer, opts \\ []),
    do: Attachments.download(pointer, [http: ctx.http, base_urls: ctx.base_urls] ++ opts)

  test "a CDN 3 upload resumes after a failed create and downloads again", ctx do
    plaintext = :crypto.strong_rand_bytes(5_000)
    FakeCdn.put_fault(ctx.cdn, :tus_create, 1_000)
    task = upload(ctx, plaintext, content_type: "audio/aac", voice_note: true)

    length = answer_form(ctx.socket, 200, tus_form(ctx, "tuskey000000000000AA"))
    assert length == Attachment.blob_size(5_000)

    assert {:ok, %Pointer{} = pointer} = Task.await(task, @wait_ms)
    assert pointer.cdn_number == 3
    assert pointer.cdn_key == "tuskey000000000000AA"
    assert pointer.size == 5_000
    assert pointer.content_type == "audio/aac"
    assert Pointer.voice_message?(pointer)
    assert byte_size(pointer.client_uuid) == 16

    assert_received {:fake_cdn, "POST", "/tus/attachments", headers, _}
    assert {"tus-resumable", "1.0.0"} in headers
    assert {"authorization", "Bearer test-token"} in headers
    assert {"upload-length", Integer.to_string(length)} in headers
    assert_received {:fake_cdn, "HEAD", "/tus/attachments/tuskey000000000000AA", _, _}
    assert_received {:fake_cdn, "PATCH", "/tus/attachments/tuskey000000000000AA", headers, rest}
    assert {"upload-offset", "1000"} in headers
    assert byte_size(rest) == length - 1_000

    assert download(ctx, pointer) == {:ok, plaintext}
    # The pointer survives the content-message encoding.
    assert {:ok, decoded} = pointer |> Pointer.encode() |> Pointer.from_binary()
    assert download(ctx, decoded) == {:ok, plaintext}
  end

  test "a CDN 2 upload resumes at the offset the session reports", ctx do
    plaintext = :crypto.strong_rand_bytes(3_000)
    FakeCdn.put_fault(ctx.cdn, :cdn2_put, 700)
    task = upload(ctx, plaintext, content_type: "image/png")

    length = Attachment.blob_size(3_000)
    answer_form(ctx.socket, 200, cdn2_form(ctx, "gcskey00000000000001", length))
    assert {:ok, pointer} = Task.await(task, @wait_ms)
    assert pointer.cdn_number == 2

    assert_received {:fake_cdn, "POST", "/cdn2/start", headers, ""}
    assert {"x-goog-resumable", "start"} in headers
    assert {"content-type", "application/octet-stream"} in headers
    assert {"content-length", "0"} in headers

    assert_received {:fake_cdn, "PUT", "/cdn2/session/0", headers, _}
    assert {"content-range", "bytes 0-#{length - 1}/#{length}"} in headers
    assert_received {:fake_cdn, "PUT", "/cdn2/session/0", headers, ""}
    assert {"content-range", "bytes */#{length}"} in headers
    assert_received {:fake_cdn, "PUT", "/cdn2/session/0", headers, _}
    assert {"content-range", "bytes 700-#{length - 1}/#{length}"} in headers

    assert download(ctx, pointer) == {:ok, plaintext}
  end

  test "a CDN 2 session that holds every byte is finished with a status query, not an empty PUT",
       ctx do
    # CRS-10 section 4.2: the failed PUT stored the whole blob, and the
    # status query reports `Range: bytes=0-<N-1>` (308). No bytes remain,
    # so the client asks for the status again instead of sending an empty
    # byte range.
    plaintext = :crypto.strong_rand_bytes(2_000)
    length = Attachment.blob_size(2_000)
    FakeCdn.put_fault(ctx.cdn, :cdn2_put, length)
    FakeCdn.put_fault(ctx.cdn, :cdn2_status, :stored_incomplete)
    task = upload(ctx, plaintext, content_type: "image/png")

    answer_form(ctx.socket, 200, cdn2_form(ctx, "gcskey00000000000002", length))
    assert {:ok, pointer} = Task.await(task, @wait_ms)

    assert_received {:fake_cdn, "PUT", "/cdn2/session/0", headers, _}
    assert {"content-range", "bytes 0-#{length - 1}/#{length}"} in headers

    for _query <- 1..2 do
      assert_received {:fake_cdn, "PUT", "/cdn2/session/0", headers, ""}
      assert {"content-range", "bytes */#{length}"} in headers
    end

    refute_received {:fake_cdn, "PUT", "/cdn2/session/0", _, _}
    assert download(ctx, pointer) == {:ok, plaintext}
  end

  test "a CDN 2 session that disappears restarts with a new form", ctx do
    plaintext = "short attachment"
    FakeCdn.put_fault(ctx.cdn, :cdn2_put, {:forget, 10})
    task = upload(ctx, plaintext, content_type: "text/plain")

    length = Attachment.blob_size(byte_size(plaintext))
    answer_form(ctx.socket, 200, cdn2_form(ctx, "firstkey000000000001", length))
    answer_form(ctx.socket, 200, cdn2_form(ctx, "secondkey00000000002", length))

    assert {:ok, %Pointer{cdn_key: "secondkey00000000002"} = pointer} = Task.await(task, @wait_ms)
    assert download(ctx, pointer) == {:ok, plaintext}
  end

  test "upload form refusals are reported", ctx do
    task = upload(ctx, "x", content_type: "text/plain")
    answer_form(ctx.socket, 413, nil)
    assert Task.await(task, @wait_ms) == {:error, :too_large}

    task = upload(ctx, "x", content_type: "text/plain")
    answer_form(ctx.socket, 429, nil, [{"retry-after", "7"}])
    assert Task.await(task, @wait_ms) == {:error, {:rate_limited, 7}}

    task = upload(ctx, "x", content_type: "text/plain")

    answer_form(ctx.socket, 200, %{
      "cdn" => 1,
      "key" => "k",
      "signedUploadLocation" => "https://x/"
    })

    assert {:error, {:invalid_form, _}} = Task.await(task, @wait_ms)
  end

  test "an MP4 video carries an incremental MAC that the download checks", ctx do
    plaintext = :crypto.strong_rand_bytes(200_000)
    task = upload(ctx, plaintext, content_type: "video/mp4")
    answer_form(ctx.socket, 200, tus_form(ctx, "videokey000000000001"))
    assert {:ok, pointer} = Task.await(task, @wait_ms)

    assert pointer.incremental_mac_chunk_size == 65_536

    assert byte_size(pointer.incremental_mac) ==
             32 * (div(Attachment.blob_size(200_000), 65_536) + 1)

    assert download(ctx, pointer) == {:ok, plaintext}

    <<first, rest::binary>> = pointer.incremental_mac
    tampered = %{pointer | incremental_mac: <<Bitwise.bxor(first, 1)>> <> rest}
    assert download(ctx, tampered) == {:error, :bad_incremental_mac}
  end

  test "downloads refuse changed blobs, missing digests and oversized bodies", ctx do
    keys = Attachment.generate_keys()

    %{blob: blob, digest: digest, size: size} =
      Attachment.encrypt("hello", keys, Attachment.generate_iv())

    FakeCdn.put_object(ctx.cdn, "attachments/stored00000000000001", blob)

    pointer = %Pointer{
      cdn_key: "stored00000000000001",
      cdn_number: 2,
      keys: keys,
      size: size,
      digest: digest
    }

    assert download(ctx, pointer) == {:ok, "hello"}
    assert download(ctx, %{pointer | digest: :crypto.hash(:sha256, "x")}) == {:error, :bad_digest}
    assert download(ctx, %{pointer | digest: nil}) == {:error, :missing_digest}
    assert download(ctx, %{pointer | digest: nil}, sticker: true) == {:ok, "hello"}
    assert download(ctx, pointer, max_bytes: 100) == {:error, :too_large}
    assert download(ctx, %{pointer | cdn_key: "missing0000000000001"}) == {:error, :not_found}
    assert download(ctx, %{pointer | cdn_number: 1}) == {:error, :unknown_cdn}

    # A legacy numeric id is fetched from CDN 0.
    FakeCdn.put_object(ctx.cdn, "attachments/4242", blob)
    legacy = %Pointer{cdn_id: 4242, keys: keys, size: size, digest: digest}
    assert download(ctx, legacy) == {:ok, "hello"}
  end

  test "download URLs follow the pointer's CDN number" do
    assert Attachments.download_url(%Pointer{cdn_key: "a/b+c", cdn_number: 3}) ==
             {:ok, "https://cdn3.signal.org/attachments/a%2Fb%2Bc"}

    assert Attachments.download_url(%Pointer{cdn_id: 7}, environment: :staging) ==
             {:ok, "https://cdn-staging.signal.org/attachments/7"}

    assert Attachments.download_url(%Pointer{content_type: "x"}) == {:error, :invalid_pointer}
  end
end
