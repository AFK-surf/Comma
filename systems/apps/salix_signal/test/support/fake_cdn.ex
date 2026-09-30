defmodule SalixSignal.Test.FakeCdn do
  @moduledoc false
  # A fake attachment and avatar CDN for tests, written from CRS-08 section
  # 5.4 and CRS-10 sections 4 and 5. It serves TLS with the FakeChat test
  # chain and keeps objects in an Agent.
  #
  #   * CDN 2 resumable sessions: POST /cdn2/start opens a session (Location
  #     /cdn2/session/<n>); PUT on a session stores bytes at the offset of its
  #     Content-Range, or answers a status query (`bytes */N`) with 200, or
  #     308 and `Range: bytes=0-<last>`.
  #   * CDN 3 TUS: POST /tus/attachments creates an upload with its body;
  #     HEAD and PATCH /tus/attachments/<key> give the offset and resume.
  #   * S3 POST /: stores the multipart `file` part under the `key` part.
  #   * GET /attachments/<key>, GET /profiles/<name>: return stored objects.
  #
  # `faults` makes the next upload request of a kind store only a prefix of
  # its body and answer 503: `%{cdn2_put: n, tus_create: n, tus_patch: n}`
  # with n the number of bytes kept. `cdn2_put: {:forget, n}` also makes
  # the session unknown afterwards (404). `cdn2_status: :stored_incomplete`
  # makes the next status query of a session that holds every byte answer
  # 308 with the full range instead of completing. A CDN 2 byte range whose
  # first byte lies past its last byte is refused with 400. Every request is
  # sent to the test process as `{:fake_cdn, method, path, headers, body}`.

  use Agent

  def start_link(test_pid) do
    Agent.start_link(fn ->
      %{test: test_pid, objects: %{}, sessions: %{}, faults: %{}, gone: MapSet.new(), next: 0}
    end)
  end

  def put_fault(cdn, kind, keep), do: Agent.update(cdn, &put_in(&1, [:faults, kind], keep))
  def object(cdn, name), do: Agent.get(cdn, &get_in(&1, [:objects, name]))
  def put_object(cdn, name, bytes), do: Agent.update(cdn, &put_in(&1, [:objects, name], bytes))

  def bandit_options(cdn, chain) do
    [
      plug: {__MODULE__.Router, cdn},
      scheme: :https,
      ip: :loopback,
      port: 0,
      thousand_island_options: [transport_options: chain.server]
    ]
  end

  defmodule Router do
    @moduledoc false
    @behaviour Plug
    import Plug.Conn

    @impl true
    def init(cdn), do: cdn

    @impl true
    def call(conn, cdn) do
      {:ok, body, conn} = read_all(conn, "")
      test = Agent.get(cdn, & &1.test)
      send(test, {:fake_cdn, conn.method, conn.request_path, conn.req_headers, body})
      route(conn, conn.method, conn.path_info, body, cdn)
    end

    defp read_all(conn, acc) do
      case read_body(conn) do
        {:ok, data, conn} -> {:ok, acc <> data, conn}
        {:more, data, conn} -> read_all(conn, acc <> data)
      end
    end

    defp route(conn, "POST", ["cdn2", "start"], _body, cdn) do
      %{"key" => key} = fetch_query_params(conn).query_params

      id =
        Agent.get_and_update(cdn, fn state ->
          id = Integer.to_string(state.next)
          sessions = state.sessions |> Map.put(id, "") |> Map.put({:key, id}, key)
          {id, %{state | next: state.next + 1, sessions: sessions}}
        end)

      location = "https://localhost:#{conn.port}/cdn2/session/#{id}"
      conn |> put_resp_header("location", location) |> send_resp(201, "")
    end

    defp route(conn, "PUT", ["cdn2", "session", id], body, cdn) do
      state = Agent.get(cdn, & &1)

      cond do
        MapSet.member?(state.gone, id) or not Map.has_key?(state.sessions, id) ->
          send_resp(conn, 404, "")

        true ->
          stored = state.sessions[id]

          case get_req_header(conn, "content-range") do
            ["bytes */" <> total] ->
              total = String.to_integer(total)

              cond do
                byte_size(stored) == total and
                    take_fault(cdn, :cdn2_status) == :stored_incomplete ->
                  conn
                  |> put_resp_header("range", "bytes=0-#{total - 1}")
                  |> send_resp(308, "")

                byte_size(stored) == total ->
                  complete_cdn2(conn, cdn, id, stored)

                stored == "" ->
                  send_resp(conn, 308, "")

                true ->
                  conn
                  |> put_resp_header("range", "bytes=0-#{byte_size(stored) - 1}")
                  |> send_resp(308, "")
              end

            ["bytes " <> range] ->
              [span, total] = String.split(range, "/")
              [offset, last] = String.split(span, "-")
              offset = String.to_integer(offset)
              total = String.to_integer(total)

              if offset > String.to_integer(last) do
                send_resp(conn, 400, "")
              else
                ^offset = byte_size(stored)
                store_cdn2(conn, cdn, id, stored, body, total)
              end
          end
      end
    end

    defp route(conn, "POST", ["tus", "attachments"], body, cdn) do
      [length] = get_req_header(conn, "upload-length")
      key = conn |> get_req_header("upload-metadata") |> hd() |> tus_key()

      case take_fault(cdn, :tus_create) do
        nil ->
          ^length = Integer.to_string(byte_size(body))
          Agent.update(cdn, &put_in(&1, [:objects, "attachments/" <> key], body))
          send_resp(conn, 201, "")

        keep ->
          Agent.update(cdn, &put_in(&1, [:sessions, "tus/" <> key], binary_part(body, 0, keep)))
          send_resp(conn, 503, "")
      end
    end

    defp route(conn, "HEAD", ["tus", "attachments", key], _body, cdn) do
      stored = Agent.get(cdn, &(&1.sessions["tus/" <> key] || ""))

      conn
      |> put_resp_header("upload-offset", Integer.to_string(byte_size(stored)))
      |> send_resp(200, "")
    end

    defp route(conn, "PATCH", ["tus", "attachments", key], body, cdn) do
      [offset] = get_req_header(conn, "upload-offset")
      stored = Agent.get(cdn, &(&1.sessions["tus/" <> key] || ""))
      ^offset = Integer.to_string(byte_size(stored))

      case take_fault(cdn, :tus_patch) do
        nil ->
          Agent.update(cdn, &put_in(&1, [:objects, "attachments/" <> key], stored <> body))
          send_resp(conn, 204, "")

        keep ->
          Agent.update(
            cdn,
            &put_in(&1, [:sessions, "tus/" <> key], stored <> binary_part(body, 0, keep))
          )

          send_resp(conn, 503, "")
      end
    end

    defp route(conn, "POST", [], body, cdn) do
      ["multipart/form-data; boundary=" <> boundary] = get_req_header(conn, "content-type")
      parts = parse_multipart(body, boundary)
      {"key", _, key} = List.keyfind(parts, "key", 0)
      {"file", _, file} = List.last(parts)
      Agent.update(cdn, &put_in(&1, [:objects, key], file))
      send_resp(conn, 204, "")
    end

    defp route(conn, "GET", path, _body, cdn) do
      case Agent.get(cdn, &get_in(&1, [:objects, Enum.join(path, "/")])) do
        nil -> send_resp(conn, 404, "")
        bytes -> send_resp(conn, 200, bytes)
      end
    end

    defp store_cdn2(conn, cdn, id, stored, body, total) do
      case take_fault(cdn, :cdn2_put) do
        nil ->
          stored = stored <> body
          Agent.update(cdn, &put_in(&1, [:sessions, id], stored))

          if byte_size(stored) == total,
            do: complete_cdn2(conn, cdn, id, stored),
            else: send_resp(conn, 308, "")

        {:forget, keep} ->
          Agent.update(cdn, fn state ->
            state = put_in(state, [:sessions, id], stored <> binary_part(body, 0, keep))
            %{state | gone: MapSet.put(state.gone, id)}
          end)

          send_resp(conn, 503, "")

        keep ->
          Agent.update(cdn, &put_in(&1, [:sessions, id], stored <> binary_part(body, 0, keep)))
          send_resp(conn, 503, "")
      end
    end

    defp complete_cdn2(conn, cdn, id, stored) do
      key = Agent.get(cdn, & &1.sessions[{:key, id}])
      Agent.update(cdn, &put_in(&1, [:objects, "attachments/" <> key], stored))
      send_resp(conn, 200, "")
    end

    defp take_fault(cdn, kind) do
      Agent.get_and_update(cdn, fn state ->
        Map.get_and_update(state, :faults, &Map.pop(&1, kind))
      end)
    end

    defp tus_key("filename " <> encoded), do: Base.decode64!(encoded)

    # Returns [{name, part_headers_text, value}] in order.
    defp parse_multipart(body, boundary) do
      body
      |> String.split("--" <> boundary)
      |> Enum.drop(1)
      |> Enum.reject(&String.starts_with?(&1, "--"))
      |> Enum.map(fn part ->
        "\r\n" <> part = part
        [head, value] = :binary.split(part, "\r\n\r\n")
        value = binary_part(value, 0, byte_size(value) - 2)
        [_, name] = Regex.run(~r/name="([^"]+)"/, head)
        {name, head, value}
      end)
    end
  end
end
