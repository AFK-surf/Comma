import type {
  AuthTestResponse,
  ChatPostMessageArguments,
  ChatPostMessageResponse,
  ConversationsRepliesArguments,
  ConversationsRepliesResponse,
  WebAPICallResult,
} from "@slack/web-api";
import type { SlackAdapterConfig } from "../config";

export type SlackAdapterOptions = Omit<
  Readonly<SlackAdapterConfig>,
  "allowedChannelIds"
> & {
  readonly allowedChannelIds: readonly string[];
};

export type SlackWebClient = {
  auth: { test(): Promise<AuthTestResponse> };
  chat: {
    postMessage(input: ChatPostMessageArguments): Promise<ChatPostMessageResponse>;
    delete?(input: { channel: string; ts: string }): Promise<WebAPICallResult>;
    getPermalink?(input: {
      channel: string;
      message_ts: string;
    }): Promise<WebAPICallResult>;
  };
  conversations: {
    replies(
      input: ConversationsRepliesArguments
    ): Promise<ConversationsRepliesResponse>;
    history?(input: Record<string, unknown>): Promise<WebAPICallResult>;
    info?(input: { channel: string }): Promise<WebAPICallResult>;
    open?(input: { users: string }): Promise<WebAPICallResult>;
    setTopic?(input: { channel: string; topic: string }): Promise<WebAPICallResult>;
    setPurpose?(input: { channel: string; purpose: string }): Promise<WebAPICallResult>;
  };
  files?: {
    uploadV2?(input: Record<string, unknown>): Promise<WebAPICallResult>;
    info?(input: { file: string }): Promise<WebAPICallResult>;
    delete?(input: { file: string }): Promise<WebAPICallResult>;
  };
  reactions?: {
    add?(input: {
      channel: string;
      timestamp: string;
      name: string;
    }): Promise<WebAPICallResult>;
    remove?(input: {
      channel: string;
      timestamp: string;
      name: string;
    }): Promise<WebAPICallResult>;
  };
  pins?: {
    add?(input: { channel: string; timestamp: string }): Promise<WebAPICallResult>;
    remove?(input: { channel: string; timestamp: string }): Promise<WebAPICallResult>;
    list?(input: { channel: string }): Promise<WebAPICallResult>;
  };
  apiCall?(method: string, input?: Record<string, unknown>): Promise<WebAPICallResult>;
};

export type SlackActorIdentity = {
  workspaceId: string;
  userId: string;
  botId?: string;
};

export type SlackPostedMessage = {
  channelId: string;
  ts: string;
  text: string;
  threadTs?: string;
};

export type SlackObservedFile = {
  id: string;
  name?: string;
  mimetype?: string;
  size?: number;
  permalink?: string;
  urlPrivate?: string;
};

export type SlackObservedReaction = {
  name: string;
  count?: number;
  userIds: string[];
};

export type SlackObservedMessage = {
  ts: string;
  text: string;
  userId?: string;
  botId?: string;
  threadTs?: string;
  subtype?: string;
  files: SlackObservedFile[];
  reactions: SlackObservedReaction[];
};

export type SlackThreadReplyWaitResult = {
  channelId: string;
  threadTs: string;
  botUserId: string;
  messages: SlackObservedMessage[];
  elapsedMs: number;
  timedOut: boolean;
};

export type SlackSetupResource =
  | {
      type: "message";
      channelId: string;
      ts: string;
      text: string;
      permalink?: string;
      threadTs?: string;
    }
  | {
      type: "file";
      channelId: string;
      fileId: string;
      filename: string;
      permalink?: string;
    };
