defmodule SalixAgent.Tools.Web do
  @moduledoc """
  Web and script tools.

  Entry shape matches the `@registry` in `SalixAgent.Tools`: `defs/0` returns
  `{name, description, fun, auto_wait_seconds}` entries, optionally followed by
  registry metadata, where `fun` is a 2-arity capture taking `(args, ctx)` with
  `ctx = %{agent_id, session_id}`.
  `web.read_pages` is read-only. `script.run_file` shares the `salix.call`
  host gateway with `script.run`, so it may produce the nested tool's journal
  events and is classified as a potential write at the outer disclosure
  boundary. Program failures become model-only failed tool results while
  preserving host events and observations completed before the failure.

  ## Tools

    * `web.read_pages` — POST
      `{urls, text: {maxCharacters: 10000}}` to `<base>/contents` with the
      `x-api-key` header. API key resolution matches `web.search` in
      `SalixAgent.Tools` (`:salix_agent, :exa_api_key`).
      Base URL is configurable via `:salix_agent, :exa_base_url` (default
      `https://api.exa.ai`, trailing slashes trimmed) so tests can mock the
      endpoint. Accepts `urls` as a JSON array **or** a comma-separated
      string, or a single `url`; blank entries are dropped and at most 10
      URLs are sent (extras silently truncated, as in Go). Output is the
      Go `formatExaContentsResults` JSON shape: `requestId` (omitted when
      empty), `count`, `results` (each with trimmed
      title/url/author/publishedDate/text plus highlights, empty fields
      omitted), and `costDollars` (omitted when absent). Non-2xx responses
      raise `web.read_pages failed: http <status>: <body[..2048]>`.

    * `script.run_file` — the C source is read from the agent-visible file
      backend (128 KiB cap, the compiler's own source bound). `env` entries
      (`[{"name", "value"}, ...]`, non-empty unique names, string values)
      reach the program as `config.env`. Execution mirrors `script.run`:
      `SalixAgent.ScriptRun.run/4` compiles and runs the program once in the
      spinfoam child, JSON-encodes the `script.result` value, appends a
      `--- console ---` section when the program logged, and returns
      `{content, events}` when host calls accumulated journal events.

    * `script.sdk` — the programming guide for `script.run` followed by the
      exact `spinfoam.h` of this node's binary (`SalixAgent.ScriptRun.Sdk`).

    * `web.http_request` — one HTTP request to a JSON API with the caller's
      method, headers, query and body; implemented in
      `SalixAgent.Tools.HttpRequest`, registered here so the web tools stay
      one area. Classified `safety: "write"`: the method decides whether it
      reads or writes, so the registry cannot promise a read.

  Skills are discovered and read through the normal fs tools under
  `/.runtime/skills`; this module intentionally has no skill discovery tool.
  """

  alias SalixAgent.FileBackend

  @exa_default_base_url "https://api.exa.ai"
  @exa_max_urls_per_request 10
  @exa_max_error_body 2048
  @exa_text_max_characters 10_000
  @max_script_file_size SalixAgent.Spinfoam.Build.max_source_bytes()
  @normal_auto_wait_seconds SalixAgent.Tools.AsyncPolicy.normal_tool_auto_wait_seconds()
  @host_gateway_opts [safety: "write"]
  @read_opts [safety: "read"]
  @write_opts [safety: "write"]

  @doc "Tool defs in stable registration order (willow registry order)."
  @spec defs() ::
          [
            {String.t(), String.t(), (map(), map() -> term()), pos_integer()}
            | {String.t(), String.t(), (map(), map() -> term()), pos_integer(), keyword()}
          ]
  def defs do
    [
      {"web.read_pages",
       "Fetch full page contents and metadata for a list of URLs using Exa AI. " <>
         "Use this tool when you need to read the actual content of web pages, " <>
         "for example after using web.search to find relevant URLs. " <>
         "Returns the full contents payload inline.", &__MODULE__.exa_contents/2,
       @normal_auto_wait_seconds},
      {"script.run_file",
       "Run a C source file from the VFS once through spinfoam, exactly like script.run (read its description and script.sdk for the API). " <>
         "env entries [{name, value}] are readable by the program as config.env strings.",
       &__MODULE__.script_run_file/2, @normal_auto_wait_seconds, @host_gateway_opts},
      {"script.sdk",
       "Read this before writing a script.run program: the exact spinfoam.h header the embedded compiler uses, the eBPF target constraints (integer C, 4 KiB stack, no heap or libc, 128 handles, 16 KiB JSON values), the compiler rules that make a program fail to build, the salix.call / script.result / script.log contract with argument and result shapes, and a complete example.",
       &__MODULE__.script_sdk/2, @normal_auto_wait_seconds, @read_opts},
      {"web.http_request",
       "Call an HTTP JSON API: one request with your choice of method (GET, POST, PUT, PATCH, DELETE, HEAD), headers, query and JSON body. " <>
         "Returns status, ok, headers and the parsed JSON body (body_text when not JSON); a non-2xx status is a result, not an error, so check ok. " <>
         "Redirects are not followed and requests are never retried. Only public http(s) hosts are reachable. " <>
         "To use a group OAuth credential, reference it with credential_env and write ${ENV_VAR} in the header value. " <>
         "The same call works from script.run through the salix.call gateway and from a background loop through sf_host_call.",
       &SalixAgent.Tools.HttpRequest.request/2, @normal_auto_wait_seconds, @write_opts}
    ]
  end

  # ---- web.read_pages ----

  @doc false
  def exa_contents(args, ctx) do
    urls = parse_urls(args)
    if urls == [], do: raise("web.read_pages: urls array cannot be empty")
    urls = Enum.take(urls, @exa_max_urls_per_request)

    api_key =
      Application.get_env(:salix_agent, :exa_api_key) ||
        raise "web.read_pages is not configured: set :salix_agent, :exa_api_key"

    body = %{urls: urls, text: %{maxCharacters: @exa_text_max_characters}}

    case Req.post(exa_base_url() <> "/contents",
           json: body,
           headers: [{"x-api-key", api_key}],
           receive_timeout: 30_000,
           retry: if(ctx[:triage_read_once] == true, do: false, else: :transient)
         ) do
      {:ok, %{status: status, body: resp}} when status in 200..299 ->
        format_contents(resp)

      {:ok, %{status: status, body: resp}} ->
        raise "web.read_pages: failed: http #{status}: #{error_body(resp)}"

      {:error, reason} ->
        raise "web.read_pages: transport error #{inspect(reason)}"
    end
  end

  defp exa_base_url do
    (Application.get_env(:salix_agent, :exa_base_url) || @exa_default_base_url)
    |> String.trim_trailing("/")
  end

  # `urls` (array or comma-separated string) or single `url`; trim + drop blanks.
  defp parse_urls(args) do
    raw = args["urls"] || args[:urls] || args["url"] || args[:url] || []

    case raw do
      list when is_list(list) -> Enum.map(list, &to_string/1)
      s when is_binary(s) -> String.split(s, ",")
      other -> [to_string(other)]
    end
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  # Mirror Go formatExaContentsResults: trimmed fields, omitempty semantics.
  defp format_contents(resp) when is_map(resp) do
    results =
      for r <- List.wrap(resp["results"]) do
        %{
          "title" => trim(r["title"]),
          "url" => trim(r["url"]),
          "author" => trim(r["author"]),
          "publishedDate" => trim(r["publishedDate"]),
          "text" => trim(r["text"]),
          "highlights" => r["highlights"] || []
        }
        |> Map.reject(fn {_k, v} -> v in ["", nil, []] end)
      end

    %{"count" => length(results), "results" => results}
    |> maybe_put("requestId", trim(resp["requestId"]))
    |> maybe_put("costDollars", resp["costDollars"])
    |> Jason.encode!()
  end

  defp format_contents(other),
    do: raise("web.read_pages: decode response: unexpected payload #{inspect(other)}")

  defp maybe_put(map, _key, empty) when empty in ["", nil], do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp trim(nil), do: ""
  defp trim(s) when is_binary(s), do: String.trim(s)
  defp trim(other), do: other |> to_string() |> String.trim()

  defp error_body(resp) do
    text =
      case resp do
        b when is_binary(b) -> b
        other -> Jason.encode!(other)
      end
      |> String.trim()

    case String.slice(text, 0, @exa_max_error_body) do
      "" -> "error"
      t -> t
    end
  end

  # ---- script.run_file / script.sdk ----

  @doc false
  def script_sdk(_args, _ctx) do
    case SalixAgent.ScriptRun.Sdk.document() do
      {:ok, document} -> document
      {:error, reason} -> raise "script.sdk unavailable on this node: #{inspect(reason)}"
    end
  end

  @doc false
  def script_run_file(args, ctx) do
    path = arg(args, "path")
    if path == "", do: raise("script.run_file: missing path")
    env = decode_script_env(args["env"] || args[:env] || [])

    code =
      case FileBackend.read(ctx, path) do
        {:ok, body, false} ->
          if byte_size(body) > @max_script_file_size do
            raise "script too large: #{byte_size(body)} bytes (limit #{@max_script_file_size})"
          end

          body

        {:ok, _body, true} ->
          raise "script too large (limit #{@max_script_file_size} bytes)"

        {:error, :not_found} ->
          raise "read vfs file: no such file: #{path}"

        {:error, reason} ->
          raise "read vfs file: #{inspect(reason)}"
      end

    SalixAgent.ScriptRun.run(%{"main.c" => code}, "main.c", env, ctx)
  end

  # Non-empty unique names, string values (the JavaScript host's contract).
  defp decode_script_env(entries) when is_list(entries) do
    Enum.reduce(entries, %{}, fn entry, acc ->
      name = entry["name"] || entry[:name] || ""
      name = name |> to_string() |> String.trim()
      if name == "", do: raise("env entries require a non-empty name")
      if Map.has_key?(acc, name), do: raise(~s(env contains duplicate name "#{name}"))
      Map.put(acc, name, to_string(entry["value"] || entry[:value] || ""))
    end)
  end

  defp decode_script_env(_), do: raise("env must be an array of {name, value} entries")

  # Same string-args pattern as SalixAgent.Tools.
  defp arg(args, key), do: to_string(args[key] || args[String.to_atom(key)] || "")
end
