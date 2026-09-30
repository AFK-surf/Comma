import { Octokit } from "@octokit/rest";
import { isHttpNotFound } from "@evalens/utils/http";

import type { ExternalResourceObservation, ExternalResourceObserver } from "./types";
import { createExternalObservation } from "./types";

export type GitHubIssueTarget =
  | { kind: "issue"; owner: string; repo: string; issueNumber: number }
  | {
      kind: "issue";
      owner: string;
      repo: string;
      /** Use a run-unique exact title so observation is independent of Agent output. */
      title: string;
      state?: "open" | "closed" | "all";
    };

export type GitHubLabelTarget = {
  kind: "label";
  owner: string;
  repo: string;
  name: string;
};

export type GitHubObservationTarget = GitHubIssueTarget | GitHubLabelTarget;

export type GitHubIssueResource = {
  owner: string;
  repo: string;
  number: number;
  title: string;
  state: string;
  url: string;
  labels: string[];
};

export type GitHubLabelResource = {
  owner: string;
  repo: string;
  name: string;
  color: string;
  description?: string;
};

export type GitHubObservation = ExternalResourceObservation<
  GitHubIssueResource | GitHubLabelResource
>;

export type GitHubObserverClient = {
  rest: {
    issues: {
      get(input: { owner: string; repo: string; issue_number: number }): Promise<{
        data: {
          number: number;
          title: string;
          state: string;
          html_url: string;
          labels: Array<string | { name?: string | null }>;
        };
      }>;
      listForRepo(input: {
        owner: string;
        repo: string;
        state: "open" | "closed" | "all";
        per_page: 100;
      }): Promise<{
        data: Array<{
          number: number;
          title: string;
          state: string;
          html_url: string;
          labels: Array<string | { name?: string | null }>;
          pull_request?: unknown;
        }>;
      }>;
      getLabel(input: { owner: string; repo: string; name: string }): Promise<{
        data: {
          name: string;
          color: string;
          description?: string | null;
        };
      }>;
    };
  };
};

export class GitHubRepositoryObserver implements ExternalResourceObserver<
  GitHubObservationTarget,
  GitHubObservation
> {
  readonly provider = "github" as const;

  constructor(
    accessToken: string,
    private readonly client: GitHubObserverClient = new Octokit({
      auth: accessToken,
    }) as unknown as GitHubObserverClient,
    private readonly now: () => Date = () => new Date()
  ) {}

  async observe(target: GitHubObservationTarget): Promise<GitHubObservation> {
    if (target.kind === "issue") return this.observeIssue(target);
    return this.observeLabel(target);
  }

  private async observeIssue(target: GitHubIssueTarget): Promise<GitHubObservation> {
    const lookup = issueLookup(target);
    try {
      const data =
        "issueNumber" in target
          ? (
              await this.client.rest.issues.get({
                owner: target.owner,
                repo: target.repo,
                issue_number: target.issueNumber,
              })
            ).data
          : (
              await this.client.rest.issues.listForRepo({
                owner: target.owner,
                repo: target.repo,
                state: target.state ?? "all",
                per_page: 100,
              })
            ).data.find((issue) => !issue.pull_request && issue.title === target.title);
      if (!data) {
        return createExternalObservation({
          provider: this.provider,
          resourceType: "issue",
          lookup,
          now: this.now,
        });
      }
      return createExternalObservation({
        provider: this.provider,
        resourceType: "issue",
        lookup,
        resource: {
          owner: target.owner,
          repo: target.repo,
          number: data.number,
          title: data.title,
          state: data.state,
          url: data.html_url,
          labels: data.labels.flatMap((label) => {
            const name = typeof label === "string" ? label : label.name;
            return name ? [name] : [];
          }),
        },
        now: this.now,
      });
    } catch (error) {
      if (!isHttpNotFound(error)) throw error;
      return createExternalObservation({
        provider: this.provider,
        resourceType: "issue",
        lookup,
        now: this.now,
      });
    }
  }

  private async observeLabel(target: GitHubLabelTarget): Promise<GitHubObservation> {
    try {
      const { data } = await this.client.rest.issues.getLabel(target);
      return createExternalObservation({
        provider: this.provider,
        resourceType: "label",
        lookup: `${target.owner}/${target.repo}:${target.name}`,
        resource: {
          owner: target.owner,
          repo: target.repo,
          name: data.name,
          color: data.color,
          ...(data.description ? { description: data.description } : {}),
        },
        now: this.now,
      });
    } catch (error) {
      if (!isHttpNotFound(error)) throw error;
      return createExternalObservation({
        provider: this.provider,
        resourceType: "label",
        lookup: `${target.owner}/${target.repo}:${target.name}`,
        now: this.now,
      });
    }
  }
}

function issueLookup(target: GitHubIssueTarget): string {
  return "issueNumber" in target
    ? `${target.owner}/${target.repo}#${target.issueNumber}`
    : `${target.owner}/${target.repo}:title=${target.title}`;
}
