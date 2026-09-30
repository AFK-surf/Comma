import type { SalixHttpAdapterOptions } from "./client";
import { SalixClient } from "./client";
import { SalixConnectorsService } from "./connectors";
import { SalixFilesService } from "./files";
import { SalixIntegrationsService } from "./integrations";
import { SalixOutputService } from "./output";
import { SalixRunsService } from "./runs";
import { SalixSessionsService } from "./sessions";
import { SalixTranscriptsService } from "./transcripts";

export type { SalixHttpAdapterOptions } from "./client";

export class SalixAdapter {
  readonly runs: SalixRunsService;
  readonly connectors: SalixConnectorsService;
  readonly sessions: SalixSessionsService;
  readonly files: SalixFilesService;
  readonly integrations: SalixIntegrationsService;
  readonly transcripts: SalixTranscriptsService;
  readonly output: SalixOutputService;

  constructor(options: SalixHttpAdapterOptions) {
    const client = new SalixClient(options);
    this.runs = new SalixRunsService(client);
    this.connectors = new SalixConnectorsService(client);
    this.files = new SalixFilesService(client);
    this.integrations = new SalixIntegrationsService(client, options.integrations);
    this.transcripts = new SalixTranscriptsService(client);
    this.sessions = new SalixSessionsService(client, this.runs, this.transcripts);
    this.output = new SalixOutputService(client, this.sessions, this.files);
  }
}
