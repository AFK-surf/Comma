export type DockerCommandResult = {
  exitCode: number;
  stdout: string;
  stderr: string;
};

export type DockerCommandOptions = {
  allowFailure?: boolean;
};

export interface DockerCommandRunner {
  run(
    args: readonly string[],
    options?: DockerCommandOptions
  ): Promise<DockerCommandResult>;
}

/** Uses Docker's official CLI so the caller's active Docker context is preserved. */
export class DockerCli implements DockerCommandRunner {
  async run(
    args: readonly string[],
    options: DockerCommandOptions = {}
  ): Promise<DockerCommandResult> {
    const child = Bun.spawn(["docker", ...args], {
      stdout: "pipe",
      stderr: "pipe",
      env: process.env,
    });
    const [exitCode, stdout, stderr] = await Promise.all([
      child.exited,
      new Response(child.stdout).text(),
      new Response(child.stderr).text(),
    ]);
    if (!options.allowFailure && exitCode !== 0) {
      throw new Error(
        `docker ${args[0] ?? "command"} failed (${exitCode}): ${stderr.slice(-4_000)}`
      );
    }
    return { exitCode, stdout, stderr };
  }
}
