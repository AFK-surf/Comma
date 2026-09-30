import { google } from "googleapis";

import type { ExternalResourceObservation, ExternalResourceObserver } from "./types";
import { createExternalObservation } from "./types";

export type GoogleWorkspaceTarget =
  | { kind: "gmail"; query: string; maxResults?: number }
  | { kind: "drive"; query: string; maxResults?: number }
  | {
      kind: "calendar";
      calendarId: string;
      query?: string;
      privateExtendedProperty?: string[];
      timeMin?: string;
      timeMax?: string;
      maxResults?: number;
    }
  | { kind: "chat"; spaceName: string; filter?: string; pageSize?: number };

export type GmailRecord = {
  id: string;
  threadId?: string;
  subject?: string;
  snippet?: string;
};

export type DriveRecord = {
  id: string;
  name: string;
  mimeType?: string;
  webViewLink?: string;
  parents: string[];
  trashed: boolean;
};

export type CalendarRecord = {
  id: string;
  summary?: string;
  status?: string;
  htmlLink?: string;
  start?: string;
  end?: string;
};

export type GoogleChatRecord = {
  name: string;
  text?: string;
  createTime?: string;
  threadName?: string;
};

export type GoogleWorkspaceResource = {
  records: Array<GmailRecord | DriveRecord | CalendarRecord | GoogleChatRecord>;
};

export type GoogleWorkspaceObservation =
  ExternalResourceObservation<GoogleWorkspaceResource>;

type GmailListResponse = { data: { messages?: Array<{ id?: string }> } };
type GmailGetResponse = {
  data: {
    id?: string | null;
    threadId?: string | null;
    snippet?: string | null;
    payload?: { headers?: Array<{ name?: string | null; value?: string | null }> };
  };
};

export type GoogleObserverClients = {
  gmail: {
    users: {
      messages: {
        list(input: {
          userId: "me";
          q: string;
          maxResults: number;
        }): Promise<GmailListResponse>;
        get(input: {
          userId: "me";
          id: string;
          format: "metadata";
          metadataHeaders: ["Subject"];
        }): Promise<GmailGetResponse>;
      };
    };
  };
  drive: {
    files: {
      list(input: { q: string; pageSize: number; fields: string }): Promise<{
        data: {
          files?: Array<{
            id?: string | null;
            name?: string | null;
            mimeType?: string | null;
            webViewLink?: string | null;
            parents?: string[] | null;
            trashed?: boolean | null;
          }>;
        };
      }>;
    };
  };
  calendar: {
    events: {
      list(input: {
        calendarId: string;
        q?: string;
        privateExtendedProperty?: string[];
        timeMin?: string;
        timeMax?: string;
        maxResults: number;
        singleEvents: true;
      }): Promise<{
        data: {
          items?: Array<{
            id?: string | null;
            summary?: string | null;
            status?: string | null;
            htmlLink?: string | null;
            start?: { dateTime?: string | null; date?: string | null };
            end?: { dateTime?: string | null; date?: string | null };
          }>;
        };
      }>;
    };
  };
  chat: {
    spaces: {
      messages: {
        list(input: { parent: string; filter?: string; pageSize: number }): Promise<{
          data: {
            messages?: Array<{
              name?: string | null;
              text?: string | null;
              createTime?: string | null;
              thread?: { name?: string | null };
            }>;
          };
        }>;
      };
    };
  };
};

export class GoogleWorkspaceObserver implements ExternalResourceObserver<
  GoogleWorkspaceTarget,
  GoogleWorkspaceObservation
> {
  readonly provider = "google" as const;

  constructor(
    accessToken: string,
    private readonly clients: GoogleObserverClients = googleClients(accessToken),
    private readonly now: () => Date = () => new Date()
  ) {}

  async observe(target: GoogleWorkspaceTarget): Promise<GoogleWorkspaceObservation> {
    switch (target.kind) {
      case "gmail":
        return this.observeGmail(target);
      case "drive":
        return this.observeDrive(target);
      case "calendar":
        return this.observeCalendar(target);
      case "chat":
        return this.observeChat(target);
    }
  }

  private async observeGmail(
    target: Extract<GoogleWorkspaceTarget, { kind: "gmail" }>
  ): Promise<GoogleWorkspaceObservation> {
    const listed = await this.clients.gmail.users.messages.list({
      userId: "me",
      q: target.query,
      maxResults: target.maxResults ?? 10,
    });
    const records = await Promise.all(
      (listed.data.messages ?? []).flatMap((message) =>
        message.id
          ? [
              this.clients.gmail.users.messages.get({
                userId: "me",
                id: message.id,
                format: "metadata",
                metadataHeaders: ["Subject"],
              }),
            ]
          : []
      )
    );
    return this.result(
      "gmail-message",
      target.query,
      records.flatMap(({ data }) => {
        if (!data.id) return [];
        const subject = data.payload?.headers?.find(
          (header) => header.name?.toLowerCase() === "subject"
        )?.value;
        return [
          {
            id: data.id,
            ...(data.threadId ? { threadId: data.threadId } : {}),
            ...(subject ? { subject } : {}),
            ...(data.snippet ? { snippet: data.snippet } : {}),
          } satisfies GmailRecord,
        ];
      })
    );
  }

  private async observeDrive(
    target: Extract<GoogleWorkspaceTarget, { kind: "drive" }>
  ): Promise<GoogleWorkspaceObservation> {
    const result = await this.clients.drive.files.list({
      q: target.query,
      pageSize: target.maxResults ?? 10,
      fields: "files(id,name,mimeType,webViewLink,parents,trashed)",
    });
    const records = (result.data.files ?? []).flatMap((file) =>
      file.id && file.name
        ? [
            {
              id: file.id,
              name: file.name,
              ...(file.mimeType ? { mimeType: file.mimeType } : {}),
              ...(file.webViewLink ? { webViewLink: file.webViewLink } : {}),
              parents: file.parents ?? [],
              trashed: file.trashed ?? false,
            } satisfies DriveRecord,
          ]
        : []
    );
    return this.result("drive-file", target.query, records);
  }

  private async observeCalendar(
    target: Extract<GoogleWorkspaceTarget, { kind: "calendar" }>
  ): Promise<GoogleWorkspaceObservation> {
    const result = await this.clients.calendar.events.list({
      calendarId: target.calendarId,
      q: target.query,
      privateExtendedProperty: target.privateExtendedProperty,
      timeMin: target.timeMin,
      timeMax: target.timeMax,
      maxResults: target.maxResults ?? 10,
      singleEvents: true,
    });
    const records = (result.data.items ?? []).flatMap((event) =>
      event.id
        ? [
            {
              id: event.id,
              ...(event.summary ? { summary: event.summary } : {}),
              ...(event.status ? { status: event.status } : {}),
              ...(event.htmlLink ? { htmlLink: event.htmlLink } : {}),
              ...(event.start?.dateTime || event.start?.date
                ? { start: event.start.dateTime ?? event.start.date! }
                : {}),
              ...(event.end?.dateTime || event.end?.date
                ? { end: event.end.dateTime ?? event.end.date! }
                : {}),
            } satisfies CalendarRecord,
          ]
        : []
    );
    return this.result(
      "calendar-event",
      `${target.calendarId}:${target.query ?? target.privateExtendedProperty?.join(",") ?? "*"}`,
      records
    );
  }

  private async observeChat(
    target: Extract<GoogleWorkspaceTarget, { kind: "chat" }>
  ): Promise<GoogleWorkspaceObservation> {
    const result = await this.clients.chat.spaces.messages.list({
      parent: target.spaceName,
      filter: target.filter,
      pageSize: target.pageSize ?? 100,
    });
    const records = (result.data.messages ?? []).flatMap((message) =>
      message.name
        ? [
            {
              name: message.name,
              ...(message.text ? { text: message.text } : {}),
              ...(message.createTime ? { createTime: message.createTime } : {}),
              ...(message.thread?.name ? { threadName: message.thread.name } : {}),
            } satisfies GoogleChatRecord,
          ]
        : []
    );
    return this.result(
      "chat-message",
      `${target.spaceName}:${target.filter ?? "*"}`,
      records
    );
  }

  private result(
    resourceType: string,
    lookup: string,
    records: GoogleWorkspaceResource["records"]
  ): GoogleWorkspaceObservation {
    return createExternalObservation({
      provider: this.provider,
      resourceType,
      lookup,
      ...(records.length > 0 ? { resource: { records } } : {}),
      now: this.now,
    });
  }
}

function googleClients(accessToken: string): GoogleObserverClients {
  const auth = new google.auth.OAuth2();
  auth.setCredentials({ access_token: accessToken });
  return {
    gmail: google.gmail({ version: "v1", auth }),
    drive: google.drive({ version: "v3", auth }),
    calendar: google.calendar({ version: "v3", auth }),
    chat: google.chat({ version: "v1", auth }),
  } as unknown as GoogleObserverClients;
}
