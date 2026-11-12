defmodule SalixStore.HeadlessInstallE2ETest do
  use SystemsClock.Case, async: false
  @moduletag :headless_install_e2e

  alias SalixStore.AgentVMMRegistrations.Headless

  # The install script runs on BusyBox, GNU coreutils and uutils (Rust
  # coreutils, the Ubuntu 26.04 default). Their tool flags differ.
  @images [
    {"busybox", "postgres:16-alpine", :required},
    {"gnu coreutils", "debian:trixie-slim", :required},
    {"uutils coreutils", "ubuntu:26.04", :optional}
  ]

  # The tests never pull. An optional image that is not local skips with a reason.
  local_image? = fn image ->
    System.find_executable("docker") != nil and
      match?({_, 0}, System.cmd("docker", ["image", "inspect", image], stderr_to_stdout: true))
  end

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "headless-install-#{SystemsRuntime.Proc.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(root, "bin"))
    File.mkdir_p!(Path.join(root, "state"))
    on_exit(fn -> File.rm_rf!(root) end)

    write_executable(
      root,
      "bin/uname",
      "#!/bin/sh\ncase \"$1\" in -s) echo Linux;; -m) echo aarch64;; esac\n"
    )

    write_executable(root, "bin/sudo", "#!/bin/sh\nexec \"$@\"\n")

    write_executable(root, "bin/curl", """
    #!/bin/sh
    printf '%s\n' "$@" >> /fixture/curl-argv
    output=''
    post=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --output) shift; output="$1" ;;
        --data-binary) post=1; cat > /fixture/request.json ;;
      esac
      shift
    done
    if [ -n "$output" ]; then
      cp /fixture/host.tar.gz "$output"
    elif [ "$post" = 1 ]; then
      if [ -e /fixture/fail-download ]; then exit 22; fi
      cat /fixture/install.sh
    else
      cat /fixture/bootstrap.sh
    fi
    """)

    release = Path.join(root, "release")
    File.mkdir_p!(release)

    write_executable(root, "release/agent-vmm", """
    #!/bin/sh
    set -eu
    printf '%s\n' "$@" >> /fixture/lifecycle-argv
    test "$*" = 'lifecycle install --registration-stdin --request-id request-1' || exit 24
    cat > /fixture/descriptor.json
    if [ -e /var/lib/agent-vmm/plan ]; then
      test "$(cat /var/lib/agent-vmm/plan)" = accepted || exit 23
      echo resumed > /fixture/result
    else
      echo accepted > /var/lib/agent-vmm/plan
      exit 17
    fi
    """)

    {_, 0} = System.cmd("tar", ["-czf", Path.join(root, "host.tar.gz"), "-C", root, "release"])
    archive = File.read!(Path.join(root, "host.tar.gz"))

    target = %{
      source: "https://artifacts.example.test/host.tar.gz",
      size: byte_size(archive),
      sha256: Base.encode16(:crypto.hash(:sha256, archive), case: :lower)
    }

    handoff = %{
      registration_id: "registration-1",
      request_id: "request-1",
      expires_at: DateTime.add(SystemsClock.utc_now(), 900, :second)
    }

    %{root: root, target: target, handoff: handoff}
  end

  for {label, image, need} <- @images do
    describe "#{label} (#{image})" do
      @describetag image: image
      if need == :optional and not local_image?.(image) do
        @describetag skip:
                       "#{image} is not in the local Docker image store; run docker pull #{image}"
      end

      test "copied command never puts its secret in a URL and resumes the exact local plan",
           ctx do
        descriptor = %{
          registration: %{id: "registration-1"},
          ticket: "fixture-secret",
          expires_at: ctx.handoff.expires_at
        }

        {:ok, command} = Headless.command(descriptor, "https://api.example.test")

        {:ok, script} =
          Headless.script(
            ctx.handoff,
            descriptor.ticket,
            "linux-arm64",
            ctx.target,
            "https://api.example.test"
          )

        write_command(ctx.root, command)
        File.write!(Path.join(ctx.root, "install.sh"), script)
        assert {output, 17} = run(ctx.image, ctx.root, ["sh", "/fixture/command.sh"])
        assert output =~ "Install and connect this Compute Host."
        curl_argv = File.read!(Path.join(ctx.root, "curl-argv"))

        assert Jason.decode!(File.read!(Path.join(ctx.root, "request.json"))) == %{
                 "registration_id" => "registration-1",
                 "ticket" => "fixture-secret",
                 "platform" => "linux-arm64"
               }

        assert Jason.decode!(File.read!(Path.join(ctx.root, "descriptor.json")))["ticket"] ==
                 "fixture-secret"

        refute curl_argv =~ "fixture-secret"
        refute File.read!(Path.join(ctx.root, "lifecycle-argv")) =~ "fixture-secret"
        assert {_, 0} = run(ctx.image, ctx.root, ["sh", "/fixture/command.sh"])
        assert File.read!(Path.join(ctx.root, "result")) == "resumed\n"
        File.write!(Path.join(ctx.root, "state/plan"), "corrupt")
        assert {_, 23} = run(ctx.image, ctx.root, ["sh", "/fixture/command.sh"])
      end

      test "a wrong expected digest fails verification before the installer runs", ctx do
        target = %{ctx.target | sha256: String.duplicate("0", 64)}

        {:ok, script} =
          Headless.script(
            ctx.handoff,
            "secret",
            "linux-arm64",
            target,
            "https://api.example.test"
          )

        File.write!(Path.join(ctx.root, "install.sh"), script)
        assert {output, 1} = run(ctx.image, ctx.root, ["sh", "/fixture/install.sh"])
        assert output =~ "The Host archive failed verification."
        refute output =~ "Install and connect"
        refute File.exists?(Path.join(ctx.root, "lifecycle-argv"))
      end

      test "archive mutation never invokes the installer and a failed script download fails the copied command",
           ctx do
        {:ok, script} =
          Headless.script(
            ctx.handoff,
            "secret",
            "linux-arm64",
            ctx.target,
            "https://api.example.test"
          )

        File.write!(Path.join(ctx.root, "install.sh"), script)
        archive = Path.join(ctx.root, "host.tar.gz")
        <<byte, rest::binary>> = File.read!(archive)
        File.write!(archive, <<Bitwise.bxor(byte, 1), rest::binary>>)
        assert {output, 1} = run(ctx.image, ctx.root, ["sh", "/fixture/install.sh"])
        assert output =~ "failed verification"
        refute File.exists?(Path.join(ctx.root, "lifecycle-argv"))

        {:ok, command} =
          Headless.command(
            %{
              registration: %{id: "registration-1"},
              ticket: "secret",
              expires_at: ctx.handoff.expires_at
            },
            "https://api.example.test"
          )

        write_command(ctx.root, command)
        File.touch!(Path.join(ctx.root, "fail-download"))
        assert {output, 22} = run(ctx.image, ctx.root, ["sh", "/fixture/command.sh"])
        assert output =~ "install script download failed"
        refute File.exists?(Path.join(ctx.root, "lifecycle-argv"))
      end

      test "a malformed token fails before any POST", ctx do
        {:ok, bootstrap} = Headless.bootstrap("https://api.example.test")
        File.write!(Path.join(ctx.root, "bootstrap.sh"), bootstrap)

        for token <- ["operation-1", "operation-1.a.b", ".secret", "operation-1.", "op/1.secret"] do
          File.write!(
            Path.join(ctx.root, "command.sh"),
            "curl -fsSL 'https://api.example.test/v1/compute/agent-vmm/install.sh' | sh -s -- '#{token}'\n"
          )

          assert {output, 2} = run(ctx.image, ctx.root, ["sh", "/fixture/command.sh"])
          assert output =~ "install token is not valid"
          refute File.exists?(Path.join(ctx.root, "request.json"))
        end
      end
    end
  end

  # The macOS stage 2 runs here on BusyBox with the Darwin tools it calls
  # replaced by fixtures: the Host bundle's helpers record what they are given.
  describe "macOS on Apple silicon (postgres:16-alpine)" do
    @describetag image: "postgres:16-alpine"

    setup ctx do
      root = ctx.root
      File.mkdir_p!(Path.join(root, "home"))

      write_executable(
        root,
        "bin/uname",
        "#!/bin/sh\ncase \"$1\" in -s) echo Darwin;; -m) echo arm64;; esac\n"
      )

      write_executable(root, "bin/id", "#!/bin/sh\ncat /fixture/uid 2>/dev/null || echo 501\n")
      write_executable(root, "bin/shasum", "#!/bin/sh\nexec sha256sum\n")
      write_executable(root, "bin/codesign", "#!/bin/sh\nexit 0\n")

      write_executable(root, "bin/ditto", """
      #!/bin/sh
      if [ "$1" = -x ]; then tar -xzf "$3" -C "$4"; else cp -R "$1" "$2"; fi
      """)

      write_executable(root, "bin/plutil", """
      #!/bin/sh
      sed -n 's/.*"release_id":"\\([^"]*\\)".*/\\1/p'
      """)

      app = Path.join(root, "bundle/Agent VMM Host.app/Contents")
      for dir <- ["MacOS", "Helpers"], do: File.mkdir_p!(Path.join(app, dir))

      write_executable(
        root,
        "bundle/Agent VMM Host.app/Contents/MacOS/agent-vmm-host",
        "#!/bin/sh\n"
      )

      write_executable(
        root,
        "bundle/Agent VMM Host.app/Contents/Helpers/agent-vmm-service-executor",
        "#!/bin/sh\n"
      )

      write_executable(
        root,
        "bundle/Agent VMM Host.app/Contents/Helpers/agent-vmm",
        "#!/bin/sh\n"
      )

      write_executable(root, "bundle/Agent VMM Host.app/Contents/Helpers/agent-vmm-lifecycle", """
      #!/bin/sh
      set -eu
      bundle=$(cd "$(dirname "$0")/../.." && pwd)
      case "$1" in
        version) printf '{"release_id":"%s"}\\n' "$(cat "$bundle/Contents/release")"; exit 0 ;;
      esac
      printf '%s\\n' "$*" >> /fixture/lifecycle-argv
      current="$HOME/Library/Application Support/Agent VMM Host/current"
      case "$1" in
        publish-host) mkdir -p "$current"; cp -R "$3" "$current/Agent VMM Host.app" ;;
        host-maintain)
          cat > /fixture/maintain.json
          printf '%s' new-release > "$current/Agent VMM Host.app/Contents/release" ;;
        registration-claim) cat > /fixture/descriptor.json; echo claimed > /fixture/result ;;
      esac
      """)

      File.write!(Path.join(app, "release"), "new-release")

      {_, 0} =
        System.cmd("tar", [
          "-czf",
          Path.join(root, "host.tar.gz"),
          "-C",
          Path.join(root, "bundle"),
          "Agent VMM Host.app"
        ])

      archive = File.read!(Path.join(root, "host.tar.gz"))

      target = %{
        source: "https://artifacts.example.test/Agent-VMM-Host.zip",
        size: byte_size(archive),
        sha256: Base.encode16(:crypto.hash(:sha256, archive), case: :lower)
      }

      {:ok, script} =
        Headless.script(
          ctx.handoff,
          "fixture-secret",
          "darwin-arm64",
          target,
          "https://api.example.test"
        )

      File.write!(Path.join(root, "install.sh"), script)

      {:ok, command} =
        Headless.command(
          %{
            registration: %{id: "registration-1"},
            ticket: "fixture-secret",
            expires_at: ctx.handoff.expires_at
          },
          "https://api.example.test"
        )

      write_command(root, command)
      :ok
    end

    test "the copied command installs the Host as the Mac user and claims the Registration",
         ctx do
      assert {output, 0} = run(ctx.image, ctx.root, ["sh", "/fixture/command.sh"])
      assert output =~ "Install and connect this Compute Host."

      assert Jason.decode!(File.read!(Path.join(ctx.root, "request.json")))["platform"] ==
               "darwin-arm64"

      [publish, claim] =
        ctx.root |> Path.join("lifecycle-argv") |> File.read!() |> String.split("\n", trim: true)

      assert publish =~
               ~r"^publish-host --source-app /\S+/release/Agent VMM Host.app --service-type agent$"

      assert claim ==
               "registration-claim --service-type agent --disable-personal-mesh-pairing " <>
                 "--request-id request-1 --descriptor-stdin"

      descriptor = Jason.decode!(File.read!(Path.join(ctx.root, "descriptor.json")))
      assert descriptor["registration_id"] == "registration-1"
      assert descriptor["ticket"] == "fixture-secret"
      refute File.read!(Path.join(ctx.root, "lifecycle-argv")) =~ "fixture-secret"
      refute File.read!(Path.join(ctx.root, "curl-argv")) =~ "fixture-secret"
    end

    test "an installed Host of another release is updated in place before the claim", ctx do
      installed = Path.join(ctx.root, "home/Library/Application Support/Agent VMM Host/current")
      File.mkdir_p!(installed)

      {_, 0} =
        System.cmd("cp", ["-R", Path.join(ctx.root, "bundle/Agent VMM Host.app"), installed])

      File.write!(Path.join(installed, "Agent VMM Host.app/Contents/release"), "old-release")

      assert {_, 0} = run(ctx.image, ctx.root, ["sh", "/fixture/command.sh"])

      [maintain, claim] =
        ctx.root |> Path.join("lifecycle-argv") |> File.read!() |> String.split("\n", trim: true)

      assert maintain == "host-maintain --service-type auto"
      assert claim =~ "registration-claim --service-type agent"

      assert %{
               "action" => "update",
               "dataPolicy" => "preserve",
               "requestId" => "request-1-update",
               "targetReleaseId" => "new-release",
               "sourceApp" => source
             } = Jason.decode!(File.read!(Path.join(ctx.root, "maintain.json")))

      assert source =~ "/current/.Agent VMM Host.request-1.app"
    end

    test "run with sudo, it stops before the download", ctx do
      File.write!(Path.join(ctx.root, "uid"), "0\n")
      assert {output, 1} = run(ctx.image, ctx.root, ["sh", "/fixture/install.sh"])
      assert output =~ "without sudo"
      refute File.exists?(Path.join(ctx.root, "curl-argv"))
    end
  end

  defp write_command(root, command) do
    {:ok, bootstrap} = Headless.bootstrap("https://api.example.test")
    File.write!(Path.join(root, "bootstrap.sh"), bootstrap)
    File.write!(Path.join(root, "command.sh"), command.command <> "\n")
  end

  defp run(image, root, command) do
    # The CI daemon need not share the runner's filesystem. Copy the fixture
    # through Docker, and return root-owned output as files owned by the caller.
    wrapper = """
    mkdir -p /var/lib/agent-vmm || exit 97
    cp -a /fixture/state/. /var/lib/agent-vmm/ || exit 97
    "$@"
    result=$?
    rm -rf /fixture/state
    cp -a /var/lib/agent-vmm /fixture/state || exit 98
    exit "$result"
    """

    {container, 0} =
      docker(
        [
          "create",
          "--pull=never",
          "--network",
          "none",
          "--entrypoint",
          "/usr/bin/env",
          image,
          "PATH=/fixture/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
          "HOME=/fixture/home",
          "sh",
          "-c",
          wrapper,
          "--"
        ] ++ command
      )

    container = String.trim(container)

    try do
      {_, 0} = docker(["cp", root <> "/.", container <> ":/fixture"])
      {output, _} = docker(["start", "--attach", container])

      {state, 0} =
        docker(["inspect", "--format", "{{.State.Status}} {{.State.ExitCode}}", container])

      ["exited", status] = String.split(state)
      File.rm_rf!(root)
      File.mkdir_p!(root)
      {_, 0} = docker(["cp", container <> ":/fixture/.", root])
      {output, status |> String.trim() |> String.to_integer()}
    after
      docker(["rm", "--force", container])
    end
  end

  defp docker(args), do: System.cmd("docker", args, stderr_to_stdout: true)

  defp write_executable(root, path, bytes) do
    path = Path.join(root, path)
    File.write!(path, bytes)
    File.chmod!(path, 0o755)
  end
end
