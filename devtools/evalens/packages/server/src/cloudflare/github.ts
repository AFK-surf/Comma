import type { TriggerRunInput, TriggerRunResponse } from "@evalens/core/api";

export type RegisteredExperiment = {
  name: string;
  description?: string;
  module: string;
};

export type GitHubDispatcherOptions = {
  token?: string;
  owner: string;
  repo: string;
  ref: string;
  workflow?: string;
  experiments: readonly RegisteredExperiment[];
  fetch?: typeof fetch;
};

export class GitHubDispatcher {
  private readonly workflow: string;
  private readonly fetcher: typeof fetch;

  constructor(private readonly options: GitHubDispatcherOptions) {
    this.workflow = options.workflow ?? "evalens-experiment.yml";
    this.fetcher = options.fetch ?? globalThis.fetch;
  }

  listExperiments(): RegisteredExperiment[] {
    return this.options.experiments.map((experiment) => ({ ...experiment }));
  }

  async trigger(
    experimentName: string,
    input: TriggerRunInput
  ): Promise<TriggerRunResponse> {
    if (!this.options.token) {
      throw new Error("GitHub dispatch is not configured");
    }
    const experiment = this.options.experiments.find(
      ({ name }) => name === experimentName
    );
    if (!experiment) {
      throw new Error(`unknown runnable experiment: ${experimentName}`);
    }
    const response = await this.fetcher(
      `https://api.github.com/repos/${this.options.owner}/${this.options.repo}/actions/workflows/${this.workflow}/dispatches`,
      {
        method: "POST",
        headers: {
          accept: "application/vnd.github+json",
          authorization: `Bearer ${this.options.token}`,
          "content-type": "application/json",
          "user-agent": "evalens-dashboard",
          "x-github-api-version": "2022-11-28",
        },
        body: JSON.stringify({
          ref: this.options.ref,
          inputs: {
            experiment_name: experiment.name,
            experiment_module: experiment.module,
            request: JSON.stringify({
              ...(input.filter ? { filter: input.filter } : {}),
              run: input.runParams ?? {},
              eval: input.evalParams ?? {},
            }),
          },
        }),
      }
    );
    if (!response.ok) {
      throw new Error(
        `GitHub workflow dispatch failed: HTTP ${response.status} ${await response.text()}`
      );
    }
    return {
      accepted: true,
      experimentName,
      workflow: this.workflow,
      ref: this.options.ref,
    };
  }
}
