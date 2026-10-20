defmodule Mix.Tasks.Compile.VerifiedKernel do
  use Mix.Task.Compiler
  @source __DIR__

  def run(_args) do
    # CI sets this after restoring the build cached under this source's exact
    # hash; the native library is then current and the build only replays.
    if System.get_env("VERIFIED_KERNEL_PREBUILT") == "1" and
         File.exists?(Path.join(@source, "priv/verified_kernel.so")) do
      Mix.Project.build_structure()
      {:ok, []}
    else
      build()
    end
  end

  defp build do
    case System.cmd("bash", [Path.join(@source, "scripts/build.sh")], stderr_to_stdout: true) do
      {output, 0} ->
        Mix.shell().info(output)
        Mix.Project.build_structure()
        {:ok, []}

      {output, _} ->
        Mix.raise("verified kernel build failed: " <> output)
    end
  end
end

defmodule SalixVerifiedKernel.MixProject do
  use Mix.Project

  def project do
    [
      app: :salix_verified_kernel,
      version: "0.1.0",
      elixir: "~> 1.20",
      compilers: [:verified_kernel] ++ Mix.compilers(),
      deps: []
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
