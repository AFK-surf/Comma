import { LinearClient } from "@linear/sdk";
import { isHttpNotFound } from "@evalens/utils/http";

import type { ExternalResourceObservation, ExternalResourceObserver } from "./types";
import { createExternalObservation } from "./types";

export type LinearObservationTarget =
  | { kind: "issue"; idOrIdentifier: string }
  | {
      kind: "issue";
      /** Use a run-unique exact title so observation is independent of Agent output. */
      title: string;
      teamId?: string;
    }
  | { kind: "team"; id: string }
  | { kind: "project"; id: string };

type LinearNamedResource = {
  id: string;
  name: string;
};

export type LinearIssueResource = {
  id: string;
  identifier: string;
  title: string;
  priority: number;
  priorityLabel: string;
  url: string;
  team?: LinearNamedResource & { key?: string };
  project?: LinearNamedResource;
};

export type LinearTeamResource = LinearNamedResource & { key: string };
export type LinearProjectResource = LinearNamedResource & {
  slugId?: string;
  url?: string;
};

export type LinearObservation = ExternalResourceObservation<
  LinearIssueResource | LinearTeamResource | LinearProjectResource
>;

type LinearIssueLike = {
  id: string;
  identifier: string;
  title: string;
  priority: number;
  priorityLabel: string;
  url: string;
  team?: Promise<{ id: string; name: string; key?: string }>;
  project?: Promise<{ id: string; name: string }>;
};

type LinearTeamLike = { id: string; name: string; key: string };
type LinearProjectLike = {
  id: string;
  name: string;
  slugId?: string;
  url?: string;
};

export type LinearObserverClient = {
  issue(id: string): Promise<LinearIssueLike | undefined>;
  issues(input: {
    first: 50;
    filter: {
      title: { eq: string };
      team?: { id: { eq: string } };
    };
  }): Promise<{ nodes: LinearIssueLike[] }>;
  team(id: string): Promise<LinearTeamLike | undefined>;
  project(id: string): Promise<LinearProjectLike | undefined>;
};

export class LinearWorkspaceObserver implements ExternalResourceObserver<
  LinearObservationTarget,
  LinearObservation
> {
  readonly provider = "linear" as const;

  constructor(
    accessToken: string,
    private readonly client: LinearObserverClient = new LinearClient({
      apiKey: accessToken,
    }) as LinearObserverClient,
    private readonly now: () => Date = () => new Date()
  ) {}

  async observe(target: LinearObservationTarget): Promise<LinearObservation> {
    if (target.kind === "issue") {
      return this.observeIssue(target);
    }

    if (target.kind === "team") {
      const team = await this.client.team(target.id);
      return createExternalObservation({
        provider: this.provider,
        resourceType: "team",
        lookup: target.id,
        ...(team ? { resource: { id: team.id, name: team.name, key: team.key } } : {}),
        now: this.now,
      });
    }

    const project = await this.client.project(target.id);
    return createExternalObservation({
      provider: this.provider,
      resourceType: "project",
      lookup: target.id,
      ...(project
        ? {
            resource: {
              id: project.id,
              name: project.name,
              ...(project.slugId ? { slugId: project.slugId } : {}),
              ...(project.url ? { url: project.url } : {}),
            },
          }
        : {}),
      now: this.now,
    });
  }

  private async observeIssue(
    target: Extract<LinearObservationTarget, { kind: "issue" }>
  ): Promise<LinearObservation> {
    const lookup =
      "idOrIdentifier" in target ? target.idOrIdentifier : `title=${target.title}`;
    try {
      const issue =
        "idOrIdentifier" in target
          ? await this.client.issue(target.idOrIdentifier)
          : (
              await this.client.issues({
                first: 50,
                filter: {
                  title: { eq: target.title },
                  ...(target.teamId ? { team: { id: { eq: target.teamId } } } : {}),
                },
              })
            ).nodes.find((candidate) => candidate.title === target.title);
      if (!issue) return this.missing("issue", lookup);
      const [team, project] = await Promise.all([issue.team, issue.project]);
      return createExternalObservation({
        provider: this.provider,
        resourceType: "issue",
        lookup,
        resource: {
          id: issue.id,
          identifier: issue.identifier,
          title: issue.title,
          priority: issue.priority,
          priorityLabel: issue.priorityLabel,
          url: issue.url,
          ...(team
            ? {
                team: {
                  id: team.id,
                  name: team.name,
                  ...(team.key ? { key: team.key } : {}),
                },
              }
            : {}),
          ...(project ? { project: { id: project.id, name: project.name } } : {}),
        },
        now: this.now,
      });
    } catch (error) {
      if (
        !isHttpNotFound(error) &&
        !(
          typeof error === "object" &&
          error !== null &&
          "message" in error &&
          typeof error.message === "string" &&
          /(?:entity|issue).*(?:not found|does not exist)/i.test(error.message)
        )
      ) {
        throw error;
      }
      return this.missing("issue", lookup);
    }
  }

  private missing(resourceType: string, lookup: string): LinearObservation {
    return createExternalObservation({
      provider: this.provider,
      resourceType,
      lookup,
      now: this.now,
    });
  }
}
