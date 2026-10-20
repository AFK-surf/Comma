defmodule SystemsRuntime.NetworkGuard do
  @moduledoc """
  Keeps a test run off the real network (docs/testing.md#no-real-network).

  `config :systems_runtime, network_guard: true` (systems/config/test.exs)
  starts it with the runtime, so every `mix test` and every `MIX_ENV=test
  mix run` script runs under it.

    * Connections: `SystemsRuntime.NetworkGuard.TCP` is the node's TCP
      module. `:gen_tcp`, and `:ssl`, Mint, Finch, Req, `:httpc`, Postgrex and
      Redix over it, connect through it. A connection to a host that is not
      this machine is refused with `{:error, :eacces}`.
    * Name lookups: names resolve from the hosts file only and the resolver
      has no name server, so a lookup outside this machine fails at once with
      `{:error, :nxdomain}`, also where the TCP module is not asked (the
      `:inet6` option, `:inet.getaddrs/2`, `:inet_res`). Each such lookup is
      traced and counts as a refused connection.

  A refused connection or lookup fails the test it was made for (the test
  process, or a process with it in its `$callers` or `$ancestors`), naming
  the host and the test. It also fails the run when the VM exits, so code
  that rescues the error does not hide it. A connection with no test to
  attribute it to fails the run, listing the tests that were running.

  This machine is loopback, the unspecified address, its own interface
  addresses and host name, `nohost`, `*.localhost`, and the hosts in
  `COMMA_TEST_NETWORK_ALLOW` (comma-separated; names are resolved once, at
  start). Unix sockets are not checked.

  The only exception is a test with a tag from `live_tags/0`. Those tests are
  excluded by default and test an external service on purpose
  (`mix test --include live_llm --only live_llm`). In a run that includes such
  a tag, names resolve as usual and a connection with no test to attribute it
  to is allowed.

  Subprocesses inherit an environment that keeps them offline (`offline_env/0`).

  `COMMA_TEST_NETWORK=report` lets connections and lookups through and only
  reports them. With `COMMA_TEST_NETWORK_REPORT` naming a file, each report is
  also appended there as a JSON line.
  """
  use GenServer

  @table __MODULE__
  @config {__MODULE__, :config}

  # Tags of tests that reach an external service on purpose. Each one is
  # excluded from the default run in its app's test_helper.exs.
  @live_tags [:live_llm, :live_meet, :live_semantic_gpu, :browser_live]

  @closed_proxy "http://127.0.0.1:9"

  # The functions every host name lookup goes through.
  @lookups [
    {:inet, :gethostbyname_tm, 3},
    {:inet_res, :lookup, :_},
    {:inet_res, :resolve, :_},
    {:inet_res, :getbyname, :_}
  ]

  defmodule Blocked do
    @moduledoc "A test tried to reach a host that is not this machine."
    defexception [:host, :test, :location]

    @impl true
    def message(%{host: host, test: test, location: location}) do
      at = if location, do: " (#{location})", else: ""

      "tests must not use the real network: #{describe(test)} connected to #{host}#{at}. " <>
        "Use a local fixture or fake, or tag a test of an external service with one of " <>
        "#{inspect(SystemsRuntime.NetworkGuard.live_tags())} (docs/testing.md#no-real-network)"
    end

    defp describe(nil), do: "a process outside any test"
    defp describe({module, name}), do: "#{inspect(module)} \"#{name}\""
  end

  @doc "Tags that let a test reach an external service."
  def live_tags, do: @live_tags

  @doc "Environment variables that keep subprocesses offline."
  def offline_env(allow \\ []) do
    no_proxy = Enum.join(["localhost", "127.0.0.1", "::1", ".localhost" | allow], ",")

    [
      {"HTTP_PROXY", @closed_proxy},
      {"HTTPS_PROXY", @closed_proxy},
      {"ALL_PROXY", @closed_proxy},
      {"http_proxy", @closed_proxy},
      {"https_proxy", @closed_proxy},
      {"all_proxy", @closed_proxy},
      {"NO_PROXY", no_proxy},
      {"no_proxy", no_proxy},
      {"npm_config_offline", "true"},
      {"PIP_NO_INDEX", "1"},
      {"UV_OFFLINE", "1"},
      {"CARGO_NET_OFFLINE", "true"},
      {"GOPROXY", "off"},
      {"GIT_ALLOW_PROTOCOL", "file"}
    ]
  end

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    Process.flag(:trap_exit, true)
    allow = allowed_from_env()
    {:ok, hostname} = :inet.gethostname()

    # `nohost` is the host of a node that is not distributed (`nonode@nohost`).
    names =
      MapSet.new([
        "localhost",
        "nohost",
        String.downcase(to_string(hostname)) | Enum.map(allow, &String.downcase/1)
      ])

    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    for ip <- interface_addresses(), do: :ets.insert(@table, {{:ip, ip}})
    for ip <- allowed_addresses(allow), do: :ets.insert(@table, {{:ip, ip}})

    mode = if System.get_env("COMMA_TEST_NETWORK") == "report", do: :report, else: :enforce

    :persistent_term.put(@config, %{
      mode: mode,
      names: names,
      report: System.get_env("COMMA_TEST_NETWORK_REPORT")
    })

    for {key, value} <- offline_env(allow), do: System.put_env(key, value)
    if mode == :enforce and not live_arguments?(), do: resolve_from_hosts_file()
    trace_lookups()
    :ok = :inet_db.set_tcp_module(SystemsRuntime.NetworkGuard.TCP)
    System.at_exit(&at_exit/1)
    {:ok, nil}
  end

  @impl true
  def terminate(_reason, _state) do
    :inet_db.set_tcp_module(:inet_tcp)
    :persistent_term.erase(@config)
  end

  @doc false
  # Called by SystemsRuntime.NetworkGuard.TCP before it resolves `address`.
  # Returns :ok to go on, or {:error, :eacces}.
  def check_address(address) do
    case config() do
      nil ->
        :ok

      config ->
        case classify(address, config) do
          :local ->
            :ok

          {:remote, host} ->
            {:current_stacktrace, [_ | stacktrace]} = Process.info(self(), :current_stacktrace)
            refuse(host, self(), stacktrace, config)
        end
    end
  end

  @doc false
  # Called after a local name resolved: its addresses are local too.
  def resolved_local(ips) do
    if config(), do: for(ip <- ips, do: :ets.insert(@table, {{:ip, ip}}))
    :ok
  end

  @doc """
  Removes and returns the tests that `host` was refused for so far, each as
  the list of tests it was attributed to, so that refusing it on purpose (in
  the guard's own tests) does not fail the run.
  """
  def take_blocked(host) do
    for {{:blocked, ^host, running}, _} = entry <- :ets.tab2list(@table) do
      :ets.delete_object(@table, entry)
      running
    end
  end

  @doc """
  Whether `address` (a host name or an IP address) is this machine. Without
  the guard running, only loopback and `localhost` are.
  """
  def local?(address),
    do: classify(address, config() || %{names: MapSet.new(["localhost"])}) == :local

  defp config, do: :persistent_term.get(@config, nil)

  defp classify(address, _config) when is_tuple(address) do
    if local_ip?(address), do: :local, else: {:remote, address |> :inet.ntoa() |> to_string()}
  end

  defp classify(address, _config) when address in [:any, :loopback], do: :local

  defp classify(address, config) when is_atom(address),
    do: classify(Atom.to_string(address), config)

  defp classify(address, config) when is_list(address),
    do: classify(List.to_string(address), config)

  defp classify(address, config) when is_binary(address) do
    case :inet.parse_strict_address(String.to_charlist(address)) do
      {:ok, ip} ->
        classify(ip, config)

      {:error, _} ->
        name = address |> String.downcase() |> String.trim_trailing(".")

        if MapSet.member?(config.names, name) or String.ends_with?(name, ".localhost"),
          do: :local,
          else: {:remote, address}
    end
  end

  defp local_ip?({127, _, _, _}), do: true
  defp local_ip?({0, 0, 0, 0}), do: true
  defp local_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp local_ip?({0, 0, 0, 0, 0, 0, 0, 0}), do: true

  defp local_ip?({0, 0, 0, 0, 0, 0xFFFF, a, b}),
    do:
      local_ip?(
        {Bitwise.bsr(a, 8), Bitwise.band(a, 0xFF), Bitwise.bsr(b, 8), Bitwise.band(b, 0xFF)}
      )

  defp local_ip?(ip), do: :ets.whereis(@table) != :undefined and :ets.member(@table, {:ip, ip})

  # A connection or lookup of `host` by `from`. Returns :ok to let it through,
  # or {:error, :eacces}; raises when `from` is the test itself.
  defp refuse(host, from, stacktrace, config) do
    # `stacktrace` is where `from` connected or looked the host up.
    {test, tags} = find_test([from], MapSet.new(), 32)

    cond do
      Enum.any?(@live_tags, &(&1 in tags)) ->
        :ok

      test == nil and live_run?() ->
        :ok

      config.mode == :report ->
        record(host, test, location(stacktrace), config)
        :ok

      true ->
        blocked = %Blocked{host: host, test: label(test), location: location(stacktrace)}

        if record(host, test, blocked.location, config),
          do:
            :io.put_chars(:standard_error, ["[network guard] ", Exception.message(blocked), "\n"])

        cond do
          test == nil ->
            {:error, :eacces}

          test == self() ->
            raise blocked

          true ->
            # With a stacktrace, ExUnit prints the exit as the exception it is.
            Process.exit(test, {blocked, stacktrace})
            {:error, :eacces}
        end
    end
  end

  # Returns whether this host and set of tests is new.
  defp record(host, test, location, config) do
    running = if test, do: [label(test)], else: running_tests()
    new? = :ets.insert_new(@table, {{:blocked, host, running}, location})

    if new? and config.mode == :report do
      :io.put_chars(:standard_error, [
        "[network guard] report: ",
        host,
        " from ",
        Enum.map_join(running, ", ", &label_string/1),
        " at ",
        location || "?",
        "\n"
      ])

      if config.report do
        line =
          JSON.encode!(%{
            host: host,
            tests: Enum.map(running, &label_string/1),
            location: location
          })

        File.write!(config.report, [line, "\n"], [:append])
      end
    end

    new?
  end

  defp at_exit(status) do
    blocked =
      for {{:blocked, host, running}, location} <- :ets.tab2list(@table),
          do: {host, running, location}

    case config() do
      %{mode: :enforce} when blocked != [] ->
        lines =
          for {host, running, location} <- Enum.sort(blocked),
              do: [
                "  ",
                host,
                " at ",
                location || "?",
                " while running: ",
                Enum.map_join(running, ", ", &label_string/1),
                "\n"
              ]

        :io.put_chars(:standard_error, [
          "\n[network guard] tests must not use the real network; blocked connections ",
          "(docs/testing.md#no-real-network):\n",
          lines
        ])

        if status == 0, do: exit({:shutdown, 1})

      _ ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  # Names resolve from the hosts file, and the resolver has no name server
  # to ask: a lookup outside this machine fails at once.
  defp resolve_from_hosts_file do
    :ok = :inet_db.set_lookup([:file])
    # An empty resolv.conf path keeps the resolver from reading its servers again.
    :ok = :inet_db.res_option(:resolv_conf, ~c"")
    :ok = :inet_db.res_option(:nameservers, [])
    :ok = :inet_db.res_option(:alt_nameservers, [])
    # `localhost` from the resolver's own table, not the hosts file: the file
    # table is emptied for a while when a re-read of the file fails.
    :ok = :inet_db.add_host({127, 0, 0, 1}, [~c"localhost"])
    :ok = :inet_db.add_host({0, 0, 0, 0, 0, 0, 0, 1}, [~c"localhost"])
  end

  # Traces every lookup in a trace session of its own, so other tracers of
  # the node are not affected. A lookup outside this machine is refused for
  # the test that made it, as a connection is.
  defp trace_lookups do
    tracer = spawn(fn -> receive(do: ({:session, session} -> trace_loop(session, %{}))) end)
    session = :trace.session_create(__MODULE__, tracer, [])
    # The session lasts while its handle is referenced: the tracer keeps it.
    send(tracer, {:session, session})
    spec = [{:_, [], [{:message, {:current_stacktrace, 20}}]}]
    for mfa <- @lookups, do: :trace.function(session, mfa, spec, [:local])
    :trace.process(session, :all, true, [:call])
  end

  # `seen` holds the hosts each live process was refused already: one lookup
  # makes several traced calls (`:inet_res.resolve/3` calls `resolve/4`), and
  # counts once.
  defp trace_loop(session, seen) do
    receive do
      {:trace, pid, :call, {_module, _function, [name | _]}, stacktrace} ->
        hosts = Map.get(seen, pid)

        with config when config != nil <- config(),
             host when is_binary(host) <- lookup_name(name),
             {:remote, host} <- classify(host, config),
             false <- hosts != nil and MapSet.member?(hosts, host) do
          if hosts == nil, do: Process.monitor(pid)
          refuse(host, pid, stacktrace, config)
          trace_loop(session, Map.put(seen, pid, MapSet.put(hosts || MapSet.new(), host)))
        else
          _ -> trace_loop(session, seen)
        end

      {:DOWN, _ref, :process, pid, _reason} ->
        trace_loop(session, Map.delete(seen, pid))

      _other ->
        trace_loop(session, seen)
    end
  end

  # The first frame in an umbrella app (`apps/APP/...`), else the first frame
  # with a file: where the code under test connected or looked the host up.
  defp location(stacktrace) do
    frames =
      for {module, _function, _arity, info} <- stacktrace,
          info[:file],
          module not in [__MODULE__, SystemsRuntime.NetworkGuard.TCP] do
        case Regex.run(~r{/(apps/[^/]+/.+)$}, source(module)) do
          [_, path] -> {:app, "#{path}:#{info[:line]}"}
          nil -> {:other, "#{info[:file]}:#{info[:line]}"}
        end
      end

    case Enum.find(frames, &match?({:app, _}, &1)) || List.first(frames) do
      {_kind, location} -> location
      nil -> nil
    end
  end

  defp source(module) do
    to_string(module.module_info(:compile)[:source] || "")
  rescue
    _ -> ""
  end

  # The host name a lookup asks for; nil for an address.
  defp lookup_name(name) when is_atom(name), do: lookup_name(Atom.to_string(name))
  defp lookup_name(name) when is_list(name), do: lookup_name(List.to_string(name))

  defp lookup_name(name) when is_binary(name) do
    case :inet.parse_address(String.to_charlist(name)) do
      {:ok, _ip} -> nil
      _ -> name
    end
  end

  defp lookup_name(_name), do: nil

  # The test `pid` works for: itself, a process in its `$callers` or
  # `$ancestors` chain, and so on up.
  defp find_test([], _seen, _budget), do: {nil, []}
  defp find_test(_pids, _seen, 0), do: {nil, []}

  defp find_test([pid | rest], seen, budget) do
    pid = if is_atom(pid), do: Process.whereis(pid), else: pid

    if not is_pid(pid) or MapSet.member?(seen, pid) do
      find_test(rest, seen, budget)
    else
      dictionary =
        case Process.info(pid, :dictionary) do
          {:dictionary, dictionary} -> dictionary
          nil -> []
        end

      case test_label(dictionary) do
        {module, name} ->
          {pid, tags(module, name)}

        nil ->
          parents =
            Keyword.get(dictionary, :"$callers", []) ++
              Keyword.get(dictionary, :"$ancestors", [])

          find_test(rest ++ parents, MapSet.put(seen, pid), budget - 1)
      end
    end
  end

  # ExUnit labels each test process `{module, test_name}`.
  defp test_label(dictionary) do
    case Keyword.get(dictionary, :"$process_label") do
      {module, name} = label when is_atom(module) and is_atom(name) ->
        if function_exported?(module, :__ex_unit__, 0), do: label

      _ ->
        nil
    end
  end

  defp tags(module, name) do
    case Enum.find(module.__ex_unit__().tests, &(&1.name == name)) do
      %{tags: tags} -> Map.keys(tags)
      nil -> []
    end
  end

  defp label(nil), do: nil

  defp label(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} -> test_label(dictionary)
      nil -> nil
    end
  end

  defp running_tests do
    for pid <- Process.list(), label = label(pid), do: label
  end

  defp label_string({module, name}), do: "#{inspect(module)} \"#{name}\""
  defp label_string(nil), do: "(no test)"

  defp live_run? do
    included =
      if Code.ensure_loaded?(ExUnit), do: ExUnit.configuration()[:include] || [], else: []

    live_arguments?() or
      Enum.any?(included, fn
        {tag, _} -> tag in @live_tags
        tag -> tag in @live_tags
      end)
  end

  # Whether the command line includes a live tag (`--include live_llm`,
  # `--only live_llm:true`): ExUnit is configured after the runtime starts.
  defp live_arguments? do
    live = Enum.map(@live_tags, &Atom.to_string/1)

    :init.get_plain_arguments()
    |> Enum.map(&List.to_string/1)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.any?(fn [flag, tag] ->
      flag in ["--include", "--only"] and hd(String.split(tag, ":")) in live
    end)
  end

  defp allowed_from_env do
    "COMMA_TEST_NETWORK_ALLOW"
    |> System.get_env("")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
  end

  # The allowed hosts' addresses. A name is resolved now, while the resolver
  # still asks name servers, and added to the hosts table.
  defp allowed_addresses(allow) do
    Enum.flat_map(allow, fn entry ->
      address = String.to_charlist(entry)

      case :inet.parse_address(address) do
        {:ok, ip} ->
          [ip]

        {:error, _} ->
          resolved =
            for family <- [:inet, :inet6],
                {:ok, found} <- [:inet.getaddrs(address, family)],
                ip <- found,
                do: ip

          for ip <- resolved, do: :inet_db.add_host(ip, [address])
          resolved
      end
    end)
  end

  defp interface_addresses do
    case :inet.getifaddrs() do
      {:ok, interfaces} -> for {_, opts} <- interfaces, {:addr, ip} <- opts, do: ip
      {:error, _} -> []
    end
  end
end
