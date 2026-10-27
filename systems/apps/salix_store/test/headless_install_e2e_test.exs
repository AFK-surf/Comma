defmodule SalixStore.HeadlessInstallE2ETest do
  use SystemsClock.Case, async: false
  @moduletag :headless_install_e2e

  alias SalixStore.AgentVMMInstallations.Headless

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
    case "$*" in
      'lifecycle install --operation-stdin --request-id operation-1')
        cat > /fixture/descriptor.json
        mkdir -p /var/lib/agent-vmm/install-operations/operation-1
        echo accepted > /var/lib/agent-vmm/install-operations/operation-1/plan.json
        # The local plan committed, but its final reply was lost.
        exit 17 ;;
      'lifecycle install --resume-operation operation-1 --request-id operation-1')
        plan=/var/lib/agent-vmm/install-operations/operation-1/plan.json
        receipt=/var/lib/agent-vmm/install-completions/operation-1.json
        if [ -e "$plan" ]; then
          test "$(cat "$plan")" = accepted || exit 23
        else
          test "$(cat "$receipt")" = accepted || exit 23
        fi
        mkdir -p /var/lib/agent-vmm/install-completions
        echo accepted > "$receipt"
        rm -rf /var/lib/agent-vmm/install-operations/operation-1
        echo resumed > /fixture/result
        ;;
      *) exit 24 ;;
    esac
    """)

    {_, 0} = System.cmd("tar", ["-czf", Path.join(root, "host.tar.gz"), "-C", root, "release"])
    archive = File.read!(Path.join(root, "host.tar.gz"))

    target = %{
      source: "https://artifacts.example.test/host.tar.gz",
      size: byte_size(archive),
      sha256: Base.encode16(:crypto.hash(:sha256, archive), case: :lower)
    }

    handoff = %{
      operation_id: "operation-1",
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
          operation: %{id: "operation-1"},
          one_time_secret: "fixture-secret",
          expires_at: ctx.handoff.expires_at
        }

        {:ok, command} = Headless.command(descriptor, "https://api.example.test")

        {:ok, script} =
          Headless.script(
            ctx.handoff,
            descriptor.one_time_secret,
            ctx.target,
            "https://api.example.test"
          )

        write_command(ctx.root, command)
        File.write!(Path.join(ctx.root, "install.sh"), script)
        assert {output, 17} = run(ctx.image, ctx.root, ["sh", "/fixture/command.sh"])
        # The correct digest passes verification with this image's sha256sum.
        assert output =~ "Install and connect this Compute Host."
        refute output =~ "failed verification"

        # The GET bootstrap URL has no secret. The POST carries the secret in its body.
        curl_argv = File.read!(Path.join(ctx.root, "curl-argv"))
        assert curl_argv =~ "https://api.example.test/v1/compute/agent-vmm/install.sh\n"

        assert curl_argv =~
                 "https://api.example.test/v1/compute/agent-vmm/install-operations/install.sh\n"

        assert Jason.decode!(File.read!(Path.join(ctx.root, "request.json"))) == %{
                 "operation_id" => "operation-1",
                 "one_time_secret" => "fixture-secret"
               }

        assert Jason.decode!(File.read!(Path.join(ctx.root, "descriptor.json")))[
                 "one_time_secret"
               ] ==
                 "fixture-secret"

        refute curl_argv =~ "fixture-secret"
        refute File.read!(Path.join(ctx.root, "lifecycle-argv")) =~ "fixture-secret"

        # After exchange/ACK the owner returns no new descriptor. The copied command still resumes.
        {:ok, resume_script} =
          Headless.script(
            %{ctx.handoff | expires_at: nil},
            descriptor.one_time_secret,
            ctx.target,
            "https://api.example.test"
          )

        File.write!(Path.join(ctx.root, "install.sh"), resume_script)
        assert {_, 0} = run(ctx.image, ctx.root, ["sh", "/fixture/command.sh"])
        assert File.read!(Path.join(ctx.root, "result")) == "resumed\n"
        # A completion receipt also resumes after its plan has been removed.
        assert {_, 0} = run(ctx.image, ctx.root, ["sh", "/fixture/command.sh"])
        # A corrupt local plan remains a resume failure. It never starts a fresh exchange.
        File.mkdir_p!(Path.join(ctx.root, "state/install-operations/operation-1"))

        File.write!(
          Path.join(ctx.root, "state/install-operations/operation-1/plan.json"),
          "corrupt"
        )

        assert {_, 23} = run(ctx.image, ctx.root, ["sh", "/fixture/command.sh"])

        assert length(
                 Regex.scan(
                   ~r/--operation-stdin/,
                   File.read!(Path.join(ctx.root, "lifecycle-argv"))
                 )
               ) == 1
      end

      test "closed handoff without a plan fails before download", ctx do
        {:ok, script} =
          Headless.script(
            %{ctx.handoff | expires_at: nil},
            "secret",
            ctx.target,
            "https://api.example.test"
          )

        File.write!(Path.join(ctx.root, "install.sh"), script)
        assert {output, 1} = run(ctx.image, ctx.root, ["sh", "/fixture/install.sh"])
        assert output =~ "no local install plan"
        refute File.exists?(Path.join(ctx.root, "curl-argv"))
        refute File.exists?(Path.join(ctx.root, "lifecycle-argv"))
      end

      test "a wrong expected digest fails verification before the installer runs", ctx do
        target = %{ctx.target | sha256: String.duplicate("0", 64)}
        {:ok, script} = Headless.script(ctx.handoff, "secret", target, "https://api.example.test")
        File.write!(Path.join(ctx.root, "install.sh"), script)
        assert {output, 1} = run(ctx.image, ctx.root, ["sh", "/fixture/install.sh"])
        assert output =~ "The Host archive failed verification."
        refute output =~ "Install and connect"
        refute File.exists?(Path.join(ctx.root, "lifecycle-argv"))
      end

      test "archive mutation never invokes the installer and a failed script download fails the copied command",
           ctx do
        {:ok, script} =
          Headless.script(ctx.handoff, "secret", ctx.target, "https://api.example.test")

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
              operation: %{id: "operation-1"},
              one_time_secret: "secret",
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
            "curl -fsSL 'https://api.example.test/v1/compute/agent-vmm/install.sh' | sudo sh -s -- '#{token}'\n"
          )

          assert {output, 2} = run(ctx.image, ctx.root, ["sh", "/fixture/command.sh"])
          assert output =~ "install token is not valid"
          refute File.exists?(Path.join(ctx.root, "request.json"))
        end
      end
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
