import type { SlackChannel, SlackDirectory, SlackPerson } from "@comma/core/contract";
import { linkMentionPlainText } from "@comma/core/chat";
import type {
  AiInputMenuBrowse,
  AiInputMenuGroup,
  AiInputMenuItem,
} from "@comma/ui/components/ai-input";
import type { ReactNode } from "react";
import { renderToStaticMarkup } from "react-dom/server";

/** A channel names itself by its Slack link: the agent reads the team and the channel id from it. */
function channelRow(channel: SlackChannel, icon: ReactNode): AiInputMenuItem {
  const label = `#${channel.name}`;
  const href = `https://app.slack.com/client/${channel.teamId}/${channel.id}`;
  return {
    id: `channel:${channel.teamId}/${channel.id}`,
    opaqueId: true,
    label,
    searchText: channel.name,
    icon,
    tokenLabel: label,
    plainText: linkMentionPlainText(`Slack ${label}`, href),
    data: { kind: "routine-link", href },
  };
}

const personLink = (person: SlackPerson, label: string) =>
  linkMentionPlainText(label, `https://app.slack.com/team/${person.id}`);

/** A direct message names the person by their Slack profile link: the agent reads the user id from it. */
function directMessageRow(
  person: SlackPerson,
  personIcon: (person: SlackPerson) => ReactNode
): AiInputMenuItem {
  const href = `https://app.slack.com/team/${person.id}`;
  return {
    id: `person:${person.teamId}/${person.id}`,
    opaqueId: true,
    label: person.name,
    searchText: person.handle,
    description: `@${person.handle}`,
    descriptionPlacement: "inline",
    icon: personIcon(person),
    tokenLabel: person.name,
    plainText: personLink(person, `Slack DM @${person.name}`),
    data: { kind: "routine-link", href },
  };
}

/** A person named in a channel: both links, so the agent knows where and whom. */
function channelMemberRow(
  channel: SlackChannel,
  person: SlackPerson,
  personIcon: (person: SlackPerson) => ReactNode
): AiInputMenuItem {
  const row = directMessageRow(person, personIcon);
  const channelLabel = `#${channel.name}`;
  return {
    ...row,
    id: `member:${channel.id}/${person.id}`,
    tokenLabel: `${channelLabel} · ${person.name}`,
    plainText: `${channelRow(channel, null).plainText} ${personLink(person, `Slack @${person.name}`)}`,
  };
}

const whenTyped = (item: AiInputMenuItem) => ({ ...item, searchOnly: true });

/**
 * Slack's part of the "@" menu: sections that only a query lists, and the second level behind the Slack plugin's row,
 * which arranges the same rows under channels and direct messages and searches both. Behind a channel is the third and last
 * level: the whole channel, or one of its members, named together with the channel.
 */
export function slackMentionMenu(
  directory: SlackDirectory,
  labels: {
    channelsGroup: string;
    dmsGroup: string;
    channels: string;
    dms: string;
    wholeChannel: string;
    channelMembers: string;
    search: string;
    empty: string;
    noResults: string;
  },
  channelIcon: ReactNode,
  personIcon: (person: SlackPerson) => ReactNode,
  open?: { channelId: string; memberIds: readonly string[] },
  openChannel?: (channelId: string | null) => void
): { groups: AiInputMenuGroup[]; rowBrowse: AiInputMenuBrowse } {
  // Every token from here wears the Slack logo, a member's and a direct message's too.
  const tokenIconMarkup = renderToStaticMarkup(channelIcon) || undefined;
  const withLogo = (item: AiInputMenuItem): AiInputMenuItem =>
    tokenIconMarkup ? { ...item, tokenIconMarkup } : item;
  const peopleById = new Map(directory.people.map((person) => [person.id, person]));
  const channels = directory.channels.map((channel): AiInputMenuItem => {
    const row = withLogo(channelRow(channel, channelIcon));
    const members =
      open?.channelId === channel.id
        ? open.memberIds.flatMap((id) => {
            const person = peopleById.get(id);
            return person
              ? [withLogo(channelMemberRow(channel, person, personIcon))]
              : [];
          })
        : [];
    return {
      ...row,
      browse: {
        compact: true,
        label: row.label,
        title: row.label,
        searchPlaceholder: row.label,
        emptyLabel: labels.empty,
        noResultsLabel: labels.noResults,
        onQueryChange: (query) => openChannel?.(query === null ? null : channel.id),
        groups: [
          {
            id: `channel:${channel.id}/whole`,
            items: [
              { ...row, id: `channel:${channel.id}/whole`, label: labels.wholeChannel },
            ],
          },
          {
            id: `channel:${channel.id}/members`,
            label: labels.channelMembers,
            items: members,
          },
        ],
      },
    };
  });
  const dms = directory.people.map((person) =>
    withLogo(directMessageRow(person, personIcon))
  );
  return {
    groups: [
      {
        id: "slack-channels",
        label: labels.channelsGroup,
        items: channels.map(whenTyped),
      },
      {
        id: "slack-dms",
        label: labels.dmsGroup,
        items: dms.map(whenTyped),
      },
    ],
    rowBrowse: {
      label: "Slack",
      title: "Slack",
      searchPlaceholder: labels.search,
      emptyLabel: labels.empty,
      noResultsLabel: labels.noResults,
      // The query found the Slack row, not a channel or a person.
      startsUnfiltered: true,
      groups: [
        { id: "slack/channels", label: labels.channels, items: channels },
        { id: "slack/dms", label: labels.dms, items: dms },
      ],
    },
  };
}
