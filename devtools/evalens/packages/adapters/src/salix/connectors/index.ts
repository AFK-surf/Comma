import type { SalixClient } from "../client";
import { SalixConnectorCredentialsService } from "./credentials";
import { DockerCli, type DockerCommandRunner } from "./docker-cli";
import { SalixDockerConnectorsService } from "./docker";
import { SalixConnectorEnvironmentsService } from "./environments";

export * from "./credentials";
export * from "./docker";
export * from "./docker-cli";
export * from "./environments";

export class SalixConnectorsService {
  readonly credentials: SalixConnectorCredentialsService;
  readonly environments: SalixConnectorEnvironmentsService;
  readonly docker: SalixDockerConnectorsService;

  constructor(client: SalixClient, docker: DockerCommandRunner = new DockerCli()) {
    this.credentials = new SalixConnectorCredentialsService(client);
    this.environments = new SalixConnectorEnvironmentsService(client);
    this.docker = new SalixDockerConnectorsService(
      this.credentials,
      this.environments,
      docker
    );
  }
}
