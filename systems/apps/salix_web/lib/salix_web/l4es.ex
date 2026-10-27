defmodule SalixWeb.L4ES do
  @moduledoc """
  The L4ES sandbox service, as the coding sandboxes use it
  (`SalixWeb.CodingSandboxes`): create, read, stop and delete sandboxes of a Comma
  Workspace's L4ES workspace, and set its members (`comma:<id>`), through its API with a workspace
  assertion that Comma signs (l4h-sandbox DESIGN.md §28).

  Configuration (`config :salix_web, :l4es`): `url` (the L4ES public URL,
  which is also the assertions' audience), `image_manifest` (the manifest of
  the release's own sandbox image, `ensure_image/1`), else `image` (an
  operator image, default `comma-coding`), `size` (an operator size name, or
  nil for L4ES's default), `max_sandboxes` (a Workspace's live sandboxes,
  default 5) and `req_options` (tests). Without `url` the service is off.

  A Comma admin may override `max_sandboxes` for one Workspace: the tenant
  config `coding_sandboxes` (`max_sandboxes`, `sandbox_limit/1`). The
  override, else the configured default, is the limit that new sandboxes
  are checked against and that the assertions carry (`max_sandboxes/1`).

  The assertion comes from the configured signer (`config :salix_web,
  :l4es_assertion_signer`, a module with `sign/1`), which the product that
  owns the identity provider supplies. One assertion serves the calls of one
  operation; it is valid for 300 seconds at most.
  """

  require Logger

  alias SalixStore.{Ids, TenantConfigs}
  alias SalixWeb.L4ESRecent, as: Recent

  @timeout_ms 15_000
  # Calls of one operation that do not depend on each other go out together,
  # this many at a time (`concurrently/1`).
  @concurrency 8
  @limit_config "coding_sandboxes"
  # The chart accepts the same range for the default (`l4esMaxSandboxes`).
  @max_sandboxes_ceiling 100

  @doc "The L4ES settings, or nil when the service is off."
  def config do
    case SystemsRuntime.get_env(:salix_web, :l4es, []) do
      config when is_list(config) ->
        case Keyword.get(config, :url) do
          url when is_binary(url) and url != "" ->
            %{
              url: String.trim_trailing(url, "/"),
              image: Keyword.get(config, :image) || "comma-coding",
              image_manifest: present(Keyword.get(config, :image_manifest)),
              size: Keyword.get(config, :size),
              max_sandboxes: Keyword.get(config, :max_sandboxes) || 5,
              req_options: Keyword.get(config, :req_options, [])
            }

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  def enabled?, do: not is_nil(config()) and not is_nil(signer())

  @doc "The L4ES workspace of Comma Workspace `workspace_id`, as the API names it."
  def workspace_ref(workspace_id), do: "comma:" <> workspace_id

  @doc """
  An assertion for Salix in Comma Workspace `workspace_id`: `use: api`, with
  the Workspace's sandbox limit.
  """
  def assertion(workspace_id) do
    with %{} = config <- config() || {:error, :sandbox_unavailable},
         signer when not is_nil(signer) <- signer() || {:error, :sandbox_unavailable} do
      signer.sign(%{
        audience: config.url,
        workspace_id: workspace_id,
        max_sandboxes: max_sandboxes(Ids.tenant_id_from_group!(workspace_id))
      })
    end
  end

  @doc """
  The most live sandboxes a Workspace (tenant `tenant_id`) may have: its
  override, else the configured default. Nil when the service is off.
  """
  def max_sandboxes(tenant_id) when is_binary(tenant_id) do
    override(tenant_id) || default_max_sandboxes()
  end

  @doc """
  The sandbox limit of a Workspace (tenant `tenant_id`): `"override"` (nil
  when unset), `"default"` (nil when the service is off) and `"effective"`.
  """
  def sandbox_limit(tenant_id) when is_binary(tenant_id) do
    override = override(tenant_id)
    default = default_max_sandboxes()
    {:ok, %{"override" => override, "default" => default, "effective" => override || default}}
  end

  @doc """
  Sets a Workspace's own sandbox limit, an integer from 1 to 100, or clears
  it with nil. Returns `sandbox_limit/1`.
  """
  def put_sandbox_limit(tenant_id, nil) when is_binary(tenant_id) do
    :ok = TenantConfigs.delete(tenant_id, @limit_config)
    sandbox_limit(tenant_id)
  end

  def put_sandbox_limit(tenant_id, max)
      when is_binary(tenant_id) and is_integer(max) and max in 1..@max_sandboxes_ceiling do
    {:ok, _} =
      TenantConfigs.put(%{
        "tenant_id" => tenant_id,
        "name" => @limit_config,
        "value" => %{"max_sandboxes" => max},
        "updated_at" => SystemsClock.system_time(:second)
      })

    sandbox_limit(tenant_id)
  end

  def put_sandbox_limit(_tenant_id, _max),
    do:
      {:error,
       {:bad_request, "max_sandboxes must be an integer from 1 to #{@max_sandboxes_ceiling}"}}

  defp override(tenant_id) do
    case TenantConfigs.get(tenant_id, @limit_config) do
      {:ok, %{"value" => %{"max_sandboxes" => max}}} when is_integer(max) and max > 0 -> max
      _ -> nil
    end
  end

  defp default_max_sandboxes do
    case config() do
      %{max_sandboxes: max} -> max
      nil -> nil
    end
  end

  @doc """
  The image a sandbox of Comma Workspace `workspace_id` gets. With an
  `image_manifest` (`{"rootfs_sha256", "verity"}`, published by the Coding sandbox
  image workflow next to the image: `<base>/inputs/<hash>.json` names
  `<base>/<rootfs_sha256>`), the workspace's custom image of that file,
  added if it has none (`comma-<sha prefix>`), after the workspace's older
  `comma-` images are removed: L4ES keeps at most 5 a workspace, and a
  sandbox keeps the image it has until it starts again with this one. L4ES
  checks the file against its sha256, and boots it verified by its
  dm-verity descriptor (`verity`), with the initramfs of its node's
  release. A manifest without one is refused (`:image_unverified`).
  Without a manifest, the operator image `image`.
  """
  def ensure_image(workspace_id) do
    case config() do
      %{image_manifest: nil, image: image} ->
        {:ok, image}

      %{image_manifest: manifest} ->
        with {:ok, image} <- manifest_image(manifest) do
          key = {:image, workspace_id, image.sha256}

          with :error <- Recent.recall(key),
               {:ok, name} <- workspace_image(workspace_id, image) do
            Recent.remember(key, name)
            {:ok, name}
          end
        end

      nil ->
        {:error, :sandbox_unavailable}
    end
  end

  defp workspace_image(workspace_id, %{name: name, url: url, sha256: sha, verity: verity} = image) do
    with {:ok, images} <- images(workspace_id) do
      case Enum.find(images, &(&1["sha256"] == sha)) do
        %{"name" => kept} ->
          {:ok, kept}

        nil ->
          concurrently(
            for %{"name" => "comma-" <> _ = old} <- images,
                do: fn -> remove_image(workspace_id, old) end
          )

          case request(workspace_id, :post, "/images", %{
                 "name" => name,
                 "url" => url,
                 "sha256" => sha,
                 "verity" => verity
               }) do
            {:ok, status, _} when status in [200, 201] -> {:ok, name}
            # Added meanwhile by another node's create.
            {:ok, 409, body} -> added(workspace_id, image, error(body))
            {:ok, status, body} -> {:error, {:unavailable, status, error(body)}}
            {:error, _} = error -> error
          end
      end
    end
  end

  defp added(workspace_id, %{sha256: sha}, why) do
    with {:ok, images} <- images(workspace_id) do
      case Enum.find(images, &(&1["sha256"] == sha)) do
        %{"name" => name} -> {:ok, name}
        nil -> {:error, {:refused, 409, why}}
      end
    end
  end

  defp images(workspace_id) do
    case request(workspace_id, :get, "/images", nil) do
      {:ok, 200, %{"images" => images}} when is_list(images) -> {:ok, images}
      {:ok, status, body} -> {:error, {:unavailable, status, error(body)}}
      {:error, _} = error -> error
    end
  end

  defp remove_image(workspace_id, name) do
    case request(workspace_id, :delete, "/images/" <> URI.encode(name), nil) do
      {:ok, status, _} when status in [200, 204, 404] ->
        :ok

      other ->
        Logger.warning("l4es: image #{name} not removed: #{inspect(other)}")
        :ok
    end
  end

  # A manifest names one image for good (its URL holds the input hash), so
  # it is read once per node.
  defp manifest_image(manifest) do
    key = {__MODULE__, :manifest, manifest}

    case :persistent_term.get(key, nil) do
      nil ->
        with {:ok, image} <- read_manifest(manifest) do
          :persistent_term.put(key, image)
          {:ok, image}
        end

      image ->
        {:ok, image}
    end
  end

  defp read_manifest(manifest) do
    with [_, base] <-
           Regex.run(~r{^(https://.+)/inputs/[^/]+\.json$}, manifest) ||
             {:error, :bad_manifest_url} do
      [
        method: :get,
        url: manifest,
        retry: false,
        redirect: false,
        receive_timeout: @timeout_ms,
        pool_timeout: @timeout_ms,
        connect_options: [timeout: @timeout_ms],
        headers: [{"user-agent", "Comma"}]
      ]
      |> Keyword.merge(config_value(:req_options) || [])
      |> Req.request()
      |> case do
        {:ok, %Req.Response{status: 200, body: %{"rootfs_sha256" => sha} = body}}
        when is_binary(sha) ->
          with true <- sha =~ ~r/^[0-9a-f]{64}$/ || {:error, :bad_manifest},
               {:ok, verity} <- verity(body["verity"]) do
            {:ok,
             %{
               name: "comma-" <> String.slice(sha, 0, 12),
               url: base <> "/" <> sha,
               sha256: sha,
               verity: verity
             }}
          end

        {:ok, %Req.Response{status: 404}} ->
          {:error, :image_not_published}

        {:ok, %Req.Response{status: status}} ->
          {:error, {:manifest_unavailable, status}}

        {:error, reason} ->
          Logger.warning("l4es: the image manifest was not read: #{Exception.message(reason)}")
          {:error, :manifest_unreachable}
      end
    end
  end

  @doc """
  Makes Comma Workspace `workspace_id`'s L4ES workspace have exactly the
  members `members` (`%{subject, email}`: Comma users, by user id), as a
  member makes any workspace's (l4h-sandbox DESIGN.md §28.3): those
  missing are added, those no longer named removed. A member signed in to
  L4ES with Comma then finds the workspace and its sandboxes' terminals.
  """
  def set_members(workspace_id, members) when is_list(members) do
    key = {:members, workspace_id, :erlang.phash2(Enum.sort_by(members, & &1.subject))}

    with :error <- Recent.recall(key),
         :ok <- sync_members(workspace_id, members) do
      Recent.remember(key, true)
    else
      {:ok, true} -> :ok
      error -> error
    end
  end

  defp sync_members(workspace_id, members) do
    with {:ok, current} <- members(workspace_id) do
      have = MapSet.new(for %{"provider" => "comma", "subject" => s} <- current, do: s)
      want = MapSet.new(members, & &1.subject)

      added =
        for %{subject: subject} = m <- members, not MapSet.member?(have, subject) do
          body = put_present(%{"subject" => subject}, "email", m[:email])
          fn -> member_call(workspace_id, :post, "/members", body, 409) end
        end

      removed =
        for subject <- have, not MapSet.member?(want, subject) do
          path = "/members/" <> URI.encode(subject)
          fn -> member_call(workspace_id, :delete, path, nil, 404) end
        end

      concurrently(added ++ removed)
    end
  end

  # A member already added, or already gone (`done`), needs nothing more.
  defp member_call(workspace_id, method, path, body, done) do
    case request(workspace_id, method, path, body) do
      {:ok, status, _} when status in 200..299 or status == done -> :ok
      {:ok, status, body} -> {:error, {:unavailable, status, error(body)}}
      {:error, _} = error -> error
    end
  end

  # Runs `calls` (functions answering `:ok` or an error) together, at most
  # @concurrency at once, each bounded as two requests are: the first error,
  # else `:ok`.
  defp concurrently(calls) do
    calls
    |> SystemsClock.async_stream(& &1.(),
      max_concurrency: @concurrency,
      timeout: @timeout_ms * 2,
      on_timeout: :kill_task
    )
    |> Enum.reduce(:ok, fn
      {:ok, :ok}, acc -> acc
      {:ok, error}, :ok -> error
      {:exit, reason}, :ok -> {:error, {:unavailable, :timeout, inspect(reason)}}
      _, acc -> acc
    end)
  end

  defp members(workspace_id) do
    case request(workspace_id, :get, "/members", nil) do
      {:ok, 200, %{"members" => members}} when is_list(members) -> {:ok, members}
      {:ok, status, body} -> {:error, {:unavailable, status, error(body)}}
      {:error, _} = error -> error
    end
  end

  @doc """
  Ensures sandbox `name` and starts it (l4h-sandbox
  docs/sandbox-lifecycle-api.md): a new one is made; a running one is
  answered as it is; a stopped one is started again from the data disk L4ES
  kept, with this request's image, env and secrets. Every sandbox is
  semi-persistent: L4ES keeps a stopped sandbox's data disk on its node until
  it needs the space. A request the sandbox cannot take (another disk size,
  a sandbox still stopping, a running one asked to change) is refused (409).
  `opts`: `env`, `secrets`, `metadata`, `size`, `image`, and `github` (a
  GitHub ACL) with `github_token`: the sandbox reaches GitHub through its
  node's proxy, which alone holds the token (l4h-sandbox DESIGN.md §31).
  """
  def create(workspace_id, name, opts) do
    body =
      %{
        "name" => name,
        "keep" => true,
        "semi_persistent" => true,
        "image" => opts[:image] || config_value(:image),
        "env" => opts[:env] || %{},
        "secrets" => opts[:secrets] || %{},
        "metadata" => opts[:metadata] || %{}
      }
      |> put_present("size", opts[:size] || config_value(:size))
      |> put_present("github", opts[:github])
      |> put_present("github_token", opts[:github_token])

    case request(workspace_id, :post, "/sandboxes", body) do
      {:ok, status, sandbox} when status in [200, 201] -> {:ok, sandbox}
      {:ok, 409, %{"sandboxes" => _} = body} -> {:error, {:quota, body["error"]}}
      {:ok, status, body} when status in 400..499 -> {:error, {:refused, status, error(body)}}
      {:ok, status, body} -> {:error, {:unavailable, status, error(body)}}
      {:error, _} = error -> error
    end
  end

  @doc "Saves the complete GitHub ACL and queues proxy delivery. It does not replace the token."
  def update_github(workspace_id, name, github) do
    case request(workspace_id, :patch, "/sandboxes/" <> URI.encode(name), %{"github" => github}) do
      {:ok, 200, sandbox} -> {:ok, sandbox["github"] || false}
      {:ok, 404, _} -> {:error, :not_found}
      {:ok, status, body} when status in 400..499 -> {:error, {:refused, status, error(body)}}
      {:ok, status, body} -> {:error, {:unavailable, status, error(body)}}
      {:error, _} = error -> error
    end
  end

  @doc """
  Replaces the GitHub token the proxy of sandbox `name` uses, while it is
  pending, scheduled or running; other states are refused (409).
  """
  def put_github_token(workspace_id, name, token) do
    path = "/sandboxes/" <> URI.encode(name) <> "/github_token"

    case request(workspace_id, :put, path, %{"token" => token}) do
      {:ok, status, _} when status in 200..299 -> :ok
      {:ok, status, body} when status in 400..499 -> {:error, {:refused, status, error(body)}}
      {:ok, status, body} -> {:error, {:unavailable, status, error(body)}}
      {:error, _} = error -> error
    end
  end

  @doc "The newest sandbox `name`: its `state` (`stopping`, `stopped` once stopped) and `failure`."
  def get(workspace_id, name) do
    case request(workspace_id, :get, "/sandboxes/" <> URI.encode(name), nil) do
      {:ok, 200, sandbox} -> {:ok, sandbox}
      {:ok, 404, _} -> {:error, :not_found}
      {:ok, status, body} -> {:error, {:unavailable, status, error(body)}}
      {:error, _} = error -> error
    end
  end

  @doc """
  Stops sandbox `name`; L4ES keeps its data disk. A sandbox that is gone
  already is stopped too.
  """
  def stop(workspace_id, name),
    do: finish(workspace_id, :post, "/sandboxes/" <> URI.encode(name) <> "/stop?force=1")

  @doc """
  Deletes sandbox `name` and discards its data disk; the name is free again
  once L4ES confirms it stopped. A sandbox that is gone already is deleted too.
  """
  def delete(workspace_id, name),
    do: finish(workspace_id, :delete, "/sandboxes/" <> URI.encode(name) <> "?force=1")

  defp finish(workspace_id, method, path) do
    case request(workspace_id, method, path, nil) do
      {:ok, status, _} when status in [200, 204, 404] -> :ok
      {:ok, status, body} -> {:error, {:unavailable, status, error(body)}}
      {:error, _} = error -> error
    end
  end

  defp request(workspace_id, method, path, body) do
    with %{} = config <- config() || {:error, :sandbox_unavailable},
         {:ok, token} <- assertion(workspace_id) do
      url =
        config.url <>
          "/api/workspaces/" <> URI.encode(workspace_ref(workspace_id)) <> path

      [
        method: method,
        url: url,
        auth: {:bearer, token},
        retry: false,
        redirect: false,
        receive_timeout: @timeout_ms,
        pool_timeout: @timeout_ms,
        connect_options: [timeout: @timeout_ms],
        headers: [{"user-agent", "Comma"}]
      ]
      |> then(fn opts -> if body, do: Keyword.put(opts, :json, body), else: opts end)
      |> Keyword.merge(config.req_options)
      |> Req.request()
      |> case do
        {:ok, %Req.Response{status: status, body: body}} ->
          {:ok, status, if(is_map(body), do: body, else: %{})}

        {:error, reason} ->
          Logger.warning("l4es: #{method} #{path} failed: #{Exception.message(reason)}")
          {:error, :l4es_unreachable}
      end
    end
  end

  defp signer, do: SystemsRuntime.get_env(:salix_web, :l4es_assertion_signer)

  defp config_value(key), do: (config() || %{})[key]

  defp error(%{"error" => message}) when is_binary(message), do: message
  defp error(_body), do: nil

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_value), do: nil

  # The image's dm-verity descriptor, which L4ES boots it with (l4h-sandbox
  # README "Custom system images"); an image published without one cannot boot.
  defp verity(%{"root_hash" => root, "salt" => salt, "data_blocks" => blocks})
       when is_binary(root) and is_binary(salt) and is_integer(blocks) and blocks > 0 do
    if root =~ ~r/^[0-9a-f]{64}$/ and salt =~ ~r/^[0-9a-f]{64}$/,
      do: {:ok, %{"root_hash" => root, "salt" => salt, "data_blocks" => blocks}},
      else: {:error, :bad_manifest}
  end

  defp verity(_descriptor), do: {:error, :image_unverified}

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
