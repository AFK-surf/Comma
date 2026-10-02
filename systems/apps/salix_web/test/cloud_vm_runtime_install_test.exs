defmodule SalixWeb.CloudVMRuntimeInstallTest do
  use ExUnit.Case, async: true

  alias SalixWeb.CloudVM.RuntimeInstall

  @lock Jason.decode!(
          File.read!(
            Path.expand("../../../runtime-images/runtime-dependencies.lock.json", __DIR__)
          )
        )

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "runtime-install-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    bin = Path.join(root, "bin")
    base = Path.join(root, "salix")
    File.mkdir_p!(bin)
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(root) end)

    executable(Path.join(bin, "npm"), """
    #!/bin/sh
    set -eu
    while [ "$1" != "--prefix" ]; do shift; done
    prefix="$2"
    printf 'install\\n' >> "$INSTALL_CALLS"
    mkdir -p "$prefix/node_modules/.bin"
    cat > "$prefix/node_modules/.bin/codex" <<'CLI'
    #!/bin/sh
    if [ "$1" = "--version" ]; then
      if [ "${INSTALL_FAIL:-}" = 1 ]; then exit 1; fi
      echo codex-cli-#{@lock["codex"]["version"]}
      exit 0
    fi
    printf '%s\\n' "$@"
    CLI
    chmod 700 "$prefix/node_modules/.bin/codex"
    """)

    # The regression exercises installation paths, not the unchanged flock contract.
    # Linux CI uses flock. macOS uses this fixture for the same filesystem checks.
    if is_nil(System.find_executable("flock")) do
      executable(Path.join(bin, "flock"), "#!/bin/sh\nexit 0\n")
    end

    env = [
      {"PATH", bin <> ":" <> System.get_env("PATH")},
      {"HOME", root},
      {"SALIX_MANAGED_RUNTIME_ROOT", Path.join(base, "runtimes")},
      {"INSTALL_CALLS", Path.join(root, "installs")}
    ]

    %{root: root, base: base, env: env, calls: Path.join(root, "installs")}
  end

  test "repairs a partial package without changing old paths or native state", ctx do
    package = Path.join(ctx.base, "packages/codex-#{@lock["codex"]["version"]}")
    dependency = Path.join(package, "node_modules/still-used/index.js")
    File.mkdir_p!(Path.dirname(dependency))
    File.write!(dependency, "old child dependency")

    native = Path.join(ctx.base, "connector-home/native-history")
    File.mkdir_p!(Path.dirname(native))
    File.write!(native, "retained native continuation")
    auth = Path.join(ctx.base, "connector-home/auth.json")
    File.write!(auth, "retained local login")

    wrapper = Path.join(ctx.base, "runtimes/repaired/bin/codex")
    File.mkdir_p!(Path.dirname(wrapper))
    executable(wrapper, "#!/bin/sh\nexec \"#{package}/node_modules/.bin/codex\" \"$@\"\n")
    assert {_output, before_status} = System.cmd(wrapper, ["--version"], stderr_to_stdout: true)
    assert before_status != 0

    child =
      Port.open({:spawn_executable, System.find_executable("sh")}, [
        :binary,
        :exit_status,
        args: ["-c", "printf 'ready\\n'; read signal; cat \"#{dependency}\""]
      ])

    assert_receive {^child, {:data, "ready\n"}}, 1_000
    assert_install(ctx, "repaired")
    assert Port.command(child, "reopen\n")
    assert_receive {^child, {:data, "old child dependency"}}, 1_000
    assert_receive {^child, {:exit_status, 0}}, 1_000
    assert {output, 0} = System.cmd(wrapper, ["resume", "native-one"], env: ctx.env)
    assert output == "resume\nnative-one\n"
    assert File.read!(dependency) == "old child dependency"
    assert File.read!(native) == "retained native continuation"
    assert File.read!(auth) == "retained local login"

    assert_install(ctx, "second")
    second = Path.join(ctx.base, "runtimes/second/bin/codex")
    assert {_, 0} = System.cmd(second, ["--version"], env: ctx.env)
    assert File.read!(ctx.calls) == "install\n"
  end

  test "a broken cache gets a new generation while earlier wrappers retain their package", ctx do
    assert_install(ctx, "original")
    original = Path.join(ctx.base, "runtimes/original/bin/codex")
    original_contents = File.read!(original)
    cache = Path.join(ctx.base, "packages/codex-#{@lock["codex"]["version"]}.current")
    broken = Path.join(ctx.base, "packages/broken-generation")
    File.mkdir_p!(Path.join(broken, "node_modules/.bin"))
    executable(Path.join(broken, "node_modules/.bin/codex"), "#!/bin/sh\nexit 1\n")
    File.rm!(cache)
    File.ln_s!(broken, cache)

    assert_install(ctx, "repaired")
    assert File.read_link!(cache) != broken
    assert File.read!(original) == original_contents
    assert {_, 0} = System.cmd(original, ["resume", "old-native"], env: ctx.env)
    repaired = Path.join(ctx.base, "runtimes/repaired/bin/codex")
    assert {_, 0} = System.cmd(repaired, ["--version"], env: ctx.env)
    assert_install(ctx, "third")
    assert File.read!(ctx.calls) == "install\ninstall\n"
  end

  test "a failed repair preserves the existing wrapper and cache", ctx do
    assert_install(ctx, "original")
    wrapper = Path.join(ctx.base, "runtimes/original/bin/codex")
    original = File.read!(wrapper)
    cache = Path.join(ctx.base, "packages/codex-#{@lock["codex"]["version"]}.current")
    cached_path = File.read_link!(cache)

    {_, status} = run_install(ctx, "original", [{"INSTALL_FAIL", "1"}])
    assert status != 0
    assert File.read!(wrapper) == original
    assert File.read_link!(cache) == cached_path
    assert {_, 0} = System.cmd(wrapper, ["--version"], env: ctx.env)
    assert File.ls!(Path.join(ctx.base, "packages")) |> length() == 2
  end

  test "wrapper publication failure retains the published package and preserves the conflicting directory",
       ctx do
    conflict = Path.join(ctx.base, "runtimes/conflict/bin/codex")
    File.mkdir_p!(conflict)
    sentinel = Path.join(conflict, "user-file")
    File.write!(sentinel, "keep")

    {_, status} = run_install(ctx, "conflict")
    assert status != 0
    assert File.read!(sentinel) == "keep"
    assert File.ls!(conflict) == ["user-file"]

    assert_install(ctx, "next")
    wrapper = Path.join(ctx.base, "runtimes/next/bin/codex")
    assert {_, 0} = System.cmd(wrapper, ["--version"], env: ctx.env)
    assert File.read!(ctx.calls) == "install\n"
  end

  defp assert_install(ctx, id) do
    {output, status} = run_install(ctx, id)
    assert status == 0, output
  end

  defp run_install(ctx, id, extra_env \\ []) do
    System.cmd("sh", ["-c", RuntimeInstall.script(id, "codex")],
      env: ctx.env ++ extra_env,
      stderr_to_stdout: true
    )
  end

  defp executable(path, contents) do
    File.write!(path, contents)
    File.chmod!(path, 0o700)
  end
end
