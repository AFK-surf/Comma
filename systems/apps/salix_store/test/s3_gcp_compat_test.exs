defmodule SalixStore.S3GCPCompatTest do
  @moduledoc """
  GCS XML API compatibility for Salix's S3 adapter. Salix's storage kernel still
  speaks in opaque `etag` CAS tokens, but in GCP mode those tokens are GCS object
  generations and conditionals are sent as `x-goog-if-generation-match`. GCS
  rejects requests that mix `x-amz-*` and `x-goog-*` headers, so this also
  checks that GCP mode uses the `GOOG4-HMAC-SHA256` signing namespace.
  """
  use ExUnit.Case, async: false

  alias SalixStore.S3.AWS

  defmodule MockGCS do
    use Agent
    import Plug.Conn

    def start_link(_opts \\ []), do: Agent.start_link(fn -> [] end, name: __MODULE__)

    def requests, do: Agent.get(__MODULE__, & &1)

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, body, conn} = read_body(conn)

      Agent.update(__MODULE__, fn requests ->
        requests ++
          [
            %{
              method: conn.method,
              path: conn.request_path,
              query: conn.query_string,
              headers: conn.req_headers,
              body: body
            }
          ]
      end)

      conn
      |> put_resp_header("etag", ~s("etag-ignored-in-gcp-mode"))
      |> put_resp_header("x-goog-generation", "42")
      |> put_resp_header("content-length", "4")
      |> respond(conn.method, conn.query_string)
    end

    defp respond(conn, "PUT", _query), do: send_resp(conn, 200, "")
    defp respond(conn, "HEAD", _query), do: send_resp(conn, 200, "")
    defp respond(conn, "DELETE", _query), do: send_resp(conn, 204, "")
    defp respond(conn, "POST", "uploads="), do: send_resp(conn, 200, "<UploadId>u1</UploadId>")
    defp respond(conn, _method, _query), do: send_resp(conn, 404, "")
  end

  setup do
    start_supervised!(MockGCS)
    port = start_bandit_retry!()

    keys = [
      :s3_endpoint,
      :s3_region,
      :s3_bucket,
      :s3_access_key_id,
      :s3_secret_access_key,
      :s3_atomic_operations,
      :s3_conditional_delete
    ]

    prev = Map.new(keys, &{&1, Application.fetch_env(:salix_store, &1)})

    Application.put_env(:salix_store, :s3_endpoint, "http://127.0.0.1:#{port}")
    Application.put_env(:salix_store, :s3_region, "auto")
    Application.put_env(:salix_store, :s3_bucket, "bucket")
    Application.put_env(:salix_store, :s3_access_key_id, "access")
    Application.put_env(:salix_store, :s3_secret_access_key, "secret")
    Application.put_env(:salix_store, :s3_atomic_operations, :gcp)
    Application.put_env(:salix_store, :s3_conditional_delete, :emulate)

    on_exit(fn ->
      Enum.each(prev, fn
        {key, {:ok, value}} -> Application.put_env(:salix_store, key, value)
        {key, :error} -> Application.delete_env(:salix_store, key)
      end)
    end)

    :ok
  end

  test "GCP mode maps Salix CAS operations to generation preconditions" do
    assert {:ok, %{etag: "42"}} =
             AWS.put("objects/head.json", "body", if_none_match: "*", meta: %{"writer" => "n1"})

    assert {:ok, %{etag: "42"}} = AWS.put("objects/head.json", "body", if_match: "42")
    assert {:ok, %{etag: "42", size: 4}} = AWS.head("objects/head.json")
    assert :ok = AWS.delete("objects/head.json", if_match: "42")

    [create, cas_put, head, delete] = MockGCS.requests()

    assert create.method == "PUT"
    assert header(create, "x-goog-if-generation-match") == "0"
    assert header(create, "x-goog-meta-writer") == "n1"
    assert header(create, "x-goog-date")
    assert header(create, "x-goog-content-sha256")
    assert String.starts_with?(header(create, "authorization"), "GOOG4-HMAC-SHA256 ")
    refute_amz_headers(create)
    refute header(create, "if-none-match")
    refute header(create, "if-match")

    assert cas_put.method == "PUT"
    assert header(cas_put, "x-goog-if-generation-match") == "42"
    refute_amz_headers(cas_put)
    refute header(cas_put, "if-match")

    assert head.method == "HEAD"
    refute_amz_headers(head)

    assert delete.method == "DELETE"
    assert header(delete, "x-goog-if-generation-match") == "42"
    refute_amz_headers(delete)
    refute header(delete, "if-match")
  end

  test "GCP mode sends generation preconditions on multipart create" do
    assert {:ok, "u1"} = AWS.multipart_create("objects/blob", if_none_match: "*")

    [create] = MockGCS.requests()
    assert create.method == "POST"
    assert create.query == "uploads="
    assert header(create, "x-goog-if-generation-match") == "0"
    refute_amz_headers(create)
    refute header(create, "if-none-match")
  end

  defp header(%{headers: headers}, name) do
    name = String.downcase(name)
    Enum.find_value(headers, fn {k, v} -> if String.downcase(k) == name, do: v end)
  end

  defp refute_amz_headers(%{headers: headers}) do
    refute Enum.any?(headers, fn {k, _v} -> String.starts_with?(String.downcase(k), "x-amz-") end)
  end

  defp start_bandit_retry! do
    Enum.find_value(1..10, fn _ ->
      port = 40_000 + :erlang.phash2(make_ref(), 20_000)

      case start_supervised({Bandit, plug: MockGCS, port: port, ip: {127, 0, 0, 1}},
             id: {:gcp_compat_bandit, port}
           ) do
        {:ok, _pid} -> port
        {:error, _} -> nil
      end
    end) || raise "could not bind a test port after 10 attempts"
  end
end
