defmodule SalixAgent.Tools.SSH do
  @moduledoc """
  `ssh.*`: outbound SSH from the platform, authenticated with the Group's SSH
  key (`SalixAgent.SSH.Identity`) and checked against the Group's
  trust-on-first-use host keys (`SalixAgent.SSH.KnownHosts`).

  `ssh.open` reaches a public `host` directly, or a Tailcat server through the
  node's Tailcat gateway (`tailcat`: an address or a DNS name with a
  `tailcat=` TXT record; `SalixAgent.SSH.TailcatGateway`).

  `ssh.open` starts a long-lived interactive PTY shell owned by the calling
  Agent session (`SalixAgent.SSH.Sessions`); the other session tools operate
  on it by `ssh_session_id`. `ssh.exec` and the SFTP tools use extra channels
  on the same connection. Failures return a JSON diagnostic with a `code` the
  Agent can act on.

  All `ssh.*` tools are public egress for information flow
  (`SalixAgent.IFC.Destination`).
  """

  alias SalixAgent.SSH.{Channels, Connection, Identity, KnownHosts, Session, Sessions}

  @short_wait SalixAgent.Tools.AsyncPolicy.normal_tool_auto_wait_seconds()
  # Output waits go up to 60 s; the round waits for them rather than turning
  # a bounded read into an async call.
  @output_wait 75
  @max_wait_seconds 60
  @default_write_wait_seconds 2
  @max_input_bytes 65_536
  @max_stdin_bytes 1_048_576
  @max_command_bytes 16_384
  @max_read_bytes 262_144
  @default_read_bytes 65_536
  @default_exec_seconds 60
  @max_exec_seconds 600
  @transfer_timeout_ms 600_000
  @dispatch_grace_ms 15_000
  @host_pattern ~S"^[A-Za-z0-9._:\[\]-]{1,253}$"
  @tailcat_pattern ~S"^[A-Za-z0-9._-]{1,2048}$"
  @user_pattern ~S"^[^\s:/\\\x00-\x1f]{1,64}$"
  @term_pattern ~S"^[a-z0-9][a-z0-9.+-]{0,31}$"
  @id_pattern ~S"^ssh_[A-Za-z0-9_-]{8,64}$"

  def defs do
    [
      {"ssh.public_key",
       "Return the Group's SSH public key and fingerprint (created on first use). Every Agent in the Group authenticates with this key: give the user the public_key line to add to ~/.ssh/authorized_keys on hosts the Agent should reach.",
       schema(%{}), &__MODULE__.public_key/2, @short_wait, [safety: "read"]},
      {"ssh.open",
       "Open a long-lived interactive SSH shell (PTY) to a public host as user, authenticated with the Group SSH key. Pass host, or tailcat instead to reach a Tailcat server (the user runs tailcat serve 22, or tailcat serve ssh, without --allow, and gives you its tailcat address or a DNS name with a tailcat= TXT record; the Group SSH key still authenticates); port is then the port on the Tailcat server. The first connection to a host trusts and records its host key; a changed key is refused with both fingerprints. Returns ssh_session_id, host_key and the first output (banner, prompt). Use ssh.write/ssh.read/ssh.screen on the session, and ssh.close when done. Sessions belong to this Agent session, close after 30 minutes without use, and do not survive Agent restarts or platform deploys; run long work under tmux or screen on the remote host. Never replayed automatically. On auth_failed, give the user the returned public_key to install.",
       schema(
         %{
           "host" => %{"type" => "string", "pattern" => @host_pattern},
           "tailcat" => %{
             "type" => "string",
             "pattern" => @tailcat_pattern,
             "description" =>
               "Instead of host: a tailcat address (tc...) or a DNS name with a tailcat= TXT record."
           },
           "port" => %{"type" => "integer", "minimum" => 1, "maximum" => 65_535},
           "user" => %{"type" => "string", "pattern" => @user_pattern},
           "term" => %{
             "type" => "string",
             "pattern" => @term_pattern,
             "description" => "TERM for the PTY, default xterm-256color."
           },
           "cols" => %{"type" => "integer", "minimum" => 20, "maximum" => 500},
           "rows" => %{"type" => "integer", "minimum" => 5, "maximum" => 200}
         },
         ["user"]
       ), &__MODULE__.open/2, @output_wait, [safety: "write"]},
      {"ssh.write",
       "Type into an SSH session: input (literal text) then keys (named keys in order, e.g. [\"enter\"], [\"ctrl_c\"], [\"up\",\"enter\"]). Returns the output produced afterwards: waits until until_text appears (literal, matched with and without terminal escapes), output goes quiet, the session closes, or wait_seconds (default 2, max 60) passes. Output is plain text; use ssh.screen for full-screen programs. Never assume a command finished unless its prompt or until_text appeared.",
       schema(
         %{
           "ssh_session_id" => id_schema(),
           "input" => %{"type" => "string", "maxLength" => @max_input_bytes},
           "keys" => %{
             "type" => "array",
             "maxItems" => 64,
             "items" => %{"type" => "string", "enum" => Session.key_names()}
           },
           "wait_seconds" => %{
             "type" => "integer",
             "minimum" => 0,
             "maximum" => @max_wait_seconds
           },
           "until_text" => %{"type" => "string", "minLength" => 1, "maxLength" => 256},
           "max_bytes" => %{"type" => "integer", "minimum" => 1, "maximum" => @max_read_bytes},
           "raw" => %{
             "type" => "boolean",
             "description" => "Return exact bytes as output_base64."
           }
         },
         ["ssh_session_id"]
       ), &__MODULE__.write/2, @output_wait, [safety: "write"]},
      {"ssh.read",
       "Read SSH session output from from_offset (use next_offset from the previous result), or the last tail_bytes. Waits up to wait_seconds (default 0, max 60) for output or until_text. truncated means older output was dropped (1 MiB is kept); more means further output is available. Also reports status, close_reason, exit_status after the shell ends.",
       schema(
         %{
           "ssh_session_id" => id_schema(),
           "from_offset" => %{"type" => "integer", "minimum" => 0},
           "tail_bytes" => %{"type" => "integer", "minimum" => 1, "maximum" => @max_read_bytes},
           "max_bytes" => %{"type" => "integer", "minimum" => 1, "maximum" => @max_read_bytes},
           "wait_seconds" => %{
             "type" => "integer",
             "minimum" => 0,
             "maximum" => @max_wait_seconds
           },
           "until_text" => %{"type" => "string", "minLength" => 1, "maxLength" => 256},
           "raw" => %{"type" => "boolean"}
         },
         ["ssh_session_id"]
       ), &__MODULE__.read/2, @output_wait, [safety: "read"]},
      {"ssh.screen",
       "Render an SSH session's current terminal screen (VT100/xterm emulation): lines, 1-based cursor position, title, and whether a full-screen program's alternate screen is active. Use it for editors, pagers, menus and progress displays.",
       schema(%{"ssh_session_id" => id_schema()}, ["ssh_session_id"]), &__MODULE__.screen/2,
       @short_wait, [safety: "read"]},
      {"ssh.resize", "Resize an SSH session's terminal.",
       schema(
         %{
           "ssh_session_id" => id_schema(),
           "cols" => %{"type" => "integer", "minimum" => 20, "maximum" => 500},
           "rows" => %{"type" => "integer", "minimum" => 5, "maximum" => 200}
         },
         ["ssh_session_id", "cols", "rows"]
       ), &__MODULE__.resize/2, @short_wait, [safety: "write"]},
      {"ssh.close",
       "Close an SSH session. The remote shell receives a hangup; running commands may be stopped. Returns the final status.",
       schema(%{"ssh_session_id" => id_schema()}, ["ssh_session_id"]), &__MODULE__.close/2,
       @short_wait, [safety: "write"]},
      {"ssh.list", "List this Agent session's SSH sessions, open and recently closed.",
       schema(%{}), &__MODULE__.list/2, @short_wait, [safety: "read"]},
      {"ssh.exec",
       "Run one command on an open SSH session's connection, outside its interactive shell, with separate stdout/stderr (256 KiB each) and exit_status. Optional stdin. timeout_seconds default 60, max 600; a timed-out command is reported, never retried.",
       schema(
         %{
           "ssh_session_id" => id_schema(),
           "command" => %{"type" => "string", "minLength" => 1, "maxLength" => @max_command_bytes},
           "stdin" => %{"type" => "string", "maxLength" => @max_stdin_bytes},
           "timeout_seconds" => %{
             "type" => "integer",
             "minimum" => 1,
             "maximum" => @max_exec_seconds
           }
         },
         ["ssh_session_id", "command"]
       ), &__MODULE__.exec/2, @short_wait, [safety: "write"]},
      {"ssh.upload",
       "Copy one file from the Agent file system (source, e.g. /reports/a.csv or /drive/...) to a path on the remote host over SFTP on an open SSH session. Up to 1 GiB. overwrite defaults to false.",
       schema(
         %{
           "ssh_session_id" => id_schema(),
           "source" => %{"type" => "string", "minLength" => 1},
           "destination" => %{"type" => "string", "minLength" => 1, "maxLength" => 4096},
           "overwrite" => %{"type" => "boolean"}
         },
         ["ssh_session_id", "source", "destination"]
       ), &__MODULE__.upload/2, @short_wait, [safety: "write"]},
      {"ssh.download",
       "Copy one regular file from the remote host (source path) into the Agent file system (destination) over SFTP on an open SSH session. Up to 1 GiB. overwrite defaults to false.",
       schema(
         %{
           "ssh_session_id" => id_schema(),
           "source" => %{"type" => "string", "minLength" => 1, "maxLength" => 4096},
           "destination" => %{"type" => "string", "minLength" => 1},
           "overwrite" => %{"type" => "boolean"}
         },
         ["ssh_session_id", "source", "destination"]
       ), &__MODULE__.download/2, @short_wait, [safety: "write"]},
      {"ssh.list_files",
       "List one remote directory over SFTP on an open SSH session: name, type, size, mode, modified_at. At most limit entries (default and max 1000).",
       schema(
         %{
           "ssh_session_id" => id_schema(),
           "path" => %{"type" => "string", "minLength" => 1, "maxLength" => 4096},
           "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 1_000}
         },
         ["ssh_session_id"]
       ), &__MODULE__.list_files/2, @short_wait, [safety: "read"]},
      {"ssh.known_hosts.list",
       "List the Group's trusted SSH host keys: name, key_type, fingerprint, first_seen_at, first_seen_by_agent_id.",
       schema(%{}), &__MODULE__.known_hosts_list/2, @short_wait, [safety: "read"]},
      {"ssh.known_hosts.remove",
       "Forget the Group's trusted host key for host and port (default 22), so the next ssh.open trusts the key the host presents. For a Tailcat server, host is the tailcat:nodekey:... host from ssh.known_hosts.list or the mismatch. Use after the user confirms a host was rebuilt; a changed key can also mean interception.",
       schema(
         %{
           "host" => %{"type" => "string", "pattern" => @host_pattern},
           "port" => %{"type" => "integer", "minimum" => 1, "maximum" => 65_535}
         },
         ["host"]
       ), &__MODULE__.known_hosts_remove/2, @short_wait, [safety: "write"]}
    ]
  end

  @doc "Dispatcher deadline for one call: the call's own wait or timeout plus grace."
  @spec dispatch_timeout_ms(String.t(), map()) :: pos_integer()
  def dispatch_timeout_ms(name, args) when name in ["ssh.write", "ssh.read"] do
    default = if name == "ssh.write", do: @default_write_wait_seconds, else: 0
    bounded(args, "wait_seconds", default, @max_wait_seconds) * 1_000 + @dispatch_grace_ms
  end

  def dispatch_timeout_ms("ssh.open", _args), do: 45_000 + @dispatch_grace_ms

  def dispatch_timeout_ms("ssh.exec", args),
    do:
      bounded(args, "timeout_seconds", @default_exec_seconds, @max_exec_seconds) * 1_000 +
        @dispatch_grace_ms

  def dispatch_timeout_ms(name, _args) when name in ["ssh.upload", "ssh.download"],
    do: @transfer_timeout_ms + @dispatch_grace_ms

  def dispatch_timeout_ms(_name, _args), do: 30_000 + @dispatch_grace_ms

  # ---- handlers -----------------------------------------------------------------

  def public_key(_args, ctx) do
    group_id = group_id!(ctx)

    case Identity.fetch(group_id) do
      {:ok, identity} ->
        ok(%{
          "public_key" => identity.public_key_line,
          "fingerprint" => identity.fingerprint,
          "key_type" => "ssh-ed25519"
        })

      {:error, reason} ->
        failure(
          Connection.diagnostic(
            "identity_unavailable",
            "The Group SSH key could not be loaded.",
            %{
              "reason" => inspect(reason)
            }
          )
        )
    end
  end

  def open(args, ctx) do
    {cols, rows} = {int(args, "cols", 120), int(args, "rows", 40)}
    {host, tailcat} = destination!(args)

    spec = %{
      id: session_id_for(ctx),
      agent_id: ctx.agent_id,
      session_id: agent_session!(ctx),
      group_id: group_id!(ctx),
      host: host,
      tailcat: tailcat,
      port: int(args, "port", 22),
      user: string!(args, "user"),
      term: Map.get(args, "term") || "xterm-256color",
      cols: cols,
      rows: rows
    }

    reply(Sessions.open(spec))
  end

  def write(args, ctx) do
    wait = bounded(args, "wait_seconds", @default_write_wait_seconds, @max_wait_seconds)
    input = Map.get(args, "input") || ""
    keys = Map.get(args, "keys") || []

    if byte_size(input) > @max_input_bytes,
      do: raise("ssh.write input exceeds #{@max_input_bytes} bytes")

    if input == "" and keys == [], do: raise("ssh.write requires input or keys")

    session_request(args, ctx, {:write, input, keys, output_opts(args, wait)}, wait * 1_000)
  end

  def read(args, ctx) do
    wait = bounded(args, "wait_seconds", 0, @max_wait_seconds)

    opts =
      args
      |> output_opts(wait)
      |> put_int(args, "from_offset", :from_offset)
      |> put_int(args, "tail_bytes", :tail_bytes)

    session_request(args, ctx, {:read, opts}, wait * 1_000)
  end

  def screen(args, ctx), do: session_request(args, ctx, :screen, 0)

  def resize(args, ctx),
    do: session_request(args, ctx, {:resize, int(args, "cols", 120), int(args, "rows", 40)}, 0)

  def close(args, ctx), do: session_request(args, ctx, {:close, "closed_by_agent"}, 0)

  def list(_args, ctx) do
    {:ok, sessions} = Sessions.list(owner(ctx))
    ok(%{"sessions" => sessions})
  end

  def exec(args, ctx) do
    command = string!(args, "command")
    stdin = Map.get(args, "stdin") || ""
    seconds = bounded(args, "timeout_seconds", @default_exec_seconds, @max_exec_seconds)

    if byte_size(command) > @max_command_bytes, do: raise("ssh.exec command is too long")
    if String.contains?(command, <<0>>), do: raise("ssh.exec command contains a NUL byte")

    args
    |> id!()
    |> connection_call(ctx, {Channels, :exec, [command, stdin, seconds * 1_000]}, seconds * 1_000)
    |> channel_reply("exec_failed")
  end

  def upload(args, ctx) do
    source = string!(args, "source")
    destination = string!(args, "destination")

    args
    |> id!()
    |> connection_call(
      ctx,
      {Channels, :upload,
       [transfer_ctx(ctx), source, destination, Map.get(args, "overwrite") == true]},
      @transfer_timeout_ms
    )
    |> channel_reply("upload_failed")
  end

  def download(args, ctx) do
    source = string!(args, "source")
    destination = string!(args, "destination")

    result =
      args
      |> id!()
      |> connection_call(
        ctx,
        {Channels, :download,
         [transfer_ctx(ctx), source, destination, Map.get(args, "overwrite") == true]},
        @transfer_timeout_ms
      )

    case result do
      {:ok, value, events} -> {Jason.encode!(value), events}
      other -> channel_reply(other, "download_failed")
    end
  end

  def list_files(args, ctx) do
    path = Map.get(args, "path") || "."

    args
    |> id!()
    |> connection_call(ctx, {Channels, :list_files, [path, int(args, "limit", 1_000)]}, 30_000)
    |> channel_reply("list_failed")
  end

  def known_hosts_list(_args, ctx) do
    case KnownHosts.list(group_id!(ctx)) do
      {:ok, entries} -> ok(%{"hosts" => entries})
      {:error, reason} -> failure(known_hosts_unavailable(reason))
    end
  end

  def known_hosts_remove(args, ctx) do
    host = args |> string!("host") |> strip_brackets()
    port = int(args, "port", 22)

    case KnownHosts.remove(group_id!(ctx), host, port) do
      {:ok, removed} ->
        ok(%{
          "name" => KnownHosts.name(host, port),
          "removed" => removed != nil,
          "entry" => removed
        })

      {:error, reason} ->
        failure(known_hosts_unavailable(reason))
    end
  end

  # ---- helpers --------------------------------------------------------------------

  # Until the gateway reports the server's node key, a Tailcat session shows
  # "tailcat" as its host: the address carries a pre-shared key.
  defp destination!(args) do
    case {Map.get(args, "host"), Map.get(args, "tailcat")} do
      {host, nil} when is_binary(host) and host != "" -> {strip_brackets(host), nil}
      {nil, target} when is_binary(target) and target != "" -> {"tailcat", String.trim(target)}
      _ -> raise "ssh.open requires exactly one of host and tailcat"
    end
  end

  defp session_request(args, ctx, message, wait_ms) do
    reply(Sessions.request(owner(ctx), id!(args), message, wait_ms + 5_000))
  end

  defp connection_call(id, ctx, mfa, timeout_ms),
    do: Sessions.with_connection(owner(ctx), id, mfa, timeout_ms)

  defp channel_reply({:ok, value}, _code), do: ok(value)
  defp channel_reply({:error, %{"code" => _} = diagnostic}, _code), do: failure(diagnostic)

  defp channel_reply({:error, reason}, code) do
    failure(Connection.diagnostic(code, channel_message(reason), %{"reason" => inspect(reason)}))
  end

  defp channel_message({:destination_exists, path}),
    do: "#{path} already exists. Pass overwrite: true to replace it."

  defp channel_message({:vfs_not_found, path}), do: "No such file: #{path}."
  defp channel_message({:too_large, max}), do: "The file exceeds the #{max}-byte transfer limit."

  defp channel_message({:not_a_regular_file, type}),
    do: "The remote path is a #{type}, not a regular file."

  defp channel_message({:sftp_unavailable, _}), do: "The host refused the SFTP subsystem."
  defp channel_message(:exec_refused), do: "The host refused to run the command."
  defp channel_message(_reason), do: "The SSH operation failed."

  defp output_opts(args, wait) do
    %{
      wait_ms: wait * 1_000,
      until_text: Map.get(args, "until_text"),
      max_bytes: args |> int("max_bytes", @default_read_bytes) |> min(@max_read_bytes) |> max(1),
      raw: Map.get(args, "raw") == true
    }
  end

  defp put_int(opts, args, key, opt) do
    case Map.get(args, key) do
      value when is_integer(value) and value >= 0 -> Map.put(opts, opt, value)
      _ -> opts
    end
  end

  defp reply({:ok, value}), do: ok(value)
  defp reply({:error, %{"code" => _} = diagnostic}), do: failure(diagnostic)

  defp reply({:error, reason}) do
    failure(
      Connection.diagnostic(
        "ssh_unavailable",
        "The SSH session could not be reached. Retry shortly.",
        %{
          "reason" => inspect(reason)
        }
      )
    )
  end

  defp ok(value), do: Jason.encode!(value)

  defp failure(%{"code" => code, "message" => message} = diagnostic) do
    {:tool_failure, Jason.encode!(%{"ok" => false, "error" => diagnostic}), code,
     "user_reportable", message, []}
  end

  defp known_hosts_unavailable(reason) do
    Connection.diagnostic(
      "known_hosts_unavailable",
      "The Group host key database could not be read or updated.",
      %{"reason" => inspect(reason)}
    )
  end

  # A retried ssh.open for the same tool call returns the same session.
  defp session_id_for(ctx) do
    seed =
      case Map.get(ctx, :tool_call_id) do
        id when is_binary(id) and id != "" -> id
        _ -> Base.encode16(:crypto.strong_rand_bytes(16))
      end

    digest =
      :crypto.hash(:sha256, [ctx.agent_id, 0, agent_session!(ctx), 0, seed])
      |> Base.url_encode64(padding: false)
      |> binary_part(0, 16)

    "ssh_" <> digest
  end

  defp owner(ctx), do: %{agent_id: ctx.agent_id, session_id: agent_session!(ctx)}

  # Transfers read and write the Agent file system with the caller's full
  # context, like `env.copy`: Drive access and information-flow labels
  # come from it.
  defp transfer_ctx(ctx), do: ctx

  defp agent_session!(ctx) do
    case Map.get(ctx, :session_id) do
      session when is_binary(session) and session != "" -> session
      _ -> raise "ssh tools require an Agent session"
    end
  end

  defp group_id!(ctx) do
    case Map.get(ctx, :group_id) do
      group when is_binary(group) and group != "" -> group
      _ -> SalixStore.Ids.group_id_from_agent!(ctx.agent_id)
    end
  rescue
    _ -> raise "ssh tools require the Agent's Group"
  end

  defp id!(args) do
    id = string!(args, "ssh_session_id")

    if Regex.match?(~r/^ssh_[A-Za-z0-9_-]{8,64}$/, id),
      do: id,
      else: raise("invalid ssh_session_id")
  end

  defp string!(args, key) do
    case Map.get(args, key) do
      value when is_binary(value) and value != "" -> value
      _ -> raise "ssh: #{key} is required"
    end
  end

  defp strip_brackets("[" <> rest), do: String.trim_trailing(rest, "]")
  defp strip_brackets(host), do: host

  defp int(args, key, default) do
    case Map.get(args, key) do
      value when is_integer(value) -> value
      _ -> default
    end
  end

  defp bounded(args, key, default, max), do: args |> int(key, default) |> max(0) |> min(max)

  defp id_schema, do: %{"type" => "string", "pattern" => @id_pattern}

  defp schema(properties, required \\ []) do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => properties,
      "required" => required
    }
  end
end
