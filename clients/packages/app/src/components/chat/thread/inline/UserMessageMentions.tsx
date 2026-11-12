import { useTopic } from "@comma/core-client";
import {
  modelMentionMatches,
  requestMentionMatches,
  slackMentionLabel,
  slackMentionMatches,
} from "@comma/core/chat";
import { CubeIcon } from "@comma/ui/components/icons";
import { RequestPersonAvatar } from "../../../tasks/RequestPersonAvatar";
import { plainTextWithLinks } from "@comma/ui/components/markdown-stream/plainTextLinks";
import { ModelVendorIcon } from "@comma/ui/components/model-icons/ModelVendorIcon";
import { resolveProviderBrandLogo } from "@comma/ui/components/provider-brand-logos";
import type { ReactNode } from "react";
import { skillMentionMatches } from "../../composer/mentions";
import { toolCommand } from "../../composer/toolCommands";
import { useWorkspaceSkills } from "../../useWorkspaceSkills";

const SlackLogo = resolveProviderBrandLogo("slack");

/** Whether the text names a model, a person asked, a Slack channel or person, a skill or a tool the bubble shows as a mention. */
export function hasUserMessageMentionCandidates(text: string) {
  return (
    !skillMentionMatches(text).next().done ||
    !modelMentionMatches(text).next().done ||
    !requestMentionMatches(text).next().done ||
    !slackMentionMatches(text).next().done
  );
}

/**
 * A run of a person's words with the models, people, Slack places, skills and tools they mentioned
 * drawn as their icon and name; the rest stays text with its links.
 */
export function userMessageMentionNodes(
  text: string,
  context: { live?: boolean | undefined; workspaceId: string }
): ReactNode[] {
  const found: { start: number; end: number; node: (key: number) => ReactNode }[] = [];
  for (const mention of modelMentionMatches(text))
    found.push({
      start: mention.start,
      end: mention.end,
      node: (key) => (
        <ModelMention
          key={key}
          live={context.live}
          modelId={mention.modelId}
          name={mention.name}
          workspaceId={context.workspaceId}
        />
      ),
    });
  for (const mention of requestMentionMatches(text))
    found.push({
      start: mention.start,
      end: mention.end,
      node: (key) => (
        <RequestMention
          grantId={mention.grantId}
          key={key}
          live={context.live}
          name={mention.name}
          workspaceId={context.workspaceId}
        />
      ),
    });
  for (const mention of slackMentionMatches(text))
    found.push({
      start: mention.start,
      end: mention.end,
      node: (key) => (
        <MentionChip
          key={key}
          icon={SlackLogo ? <SlackLogo /> : null}
          label={slackMentionLabel(mention)}
        />
      ),
    });
  // The same words the sent message attached its skills by (`deriveMentionedSkills`).
  for (const { end, skillId, start } of skillMentionMatches(text)) {
    if (found.some((other) => start < other.end && other.start < end)) continue;
    found.push({
      start,
      end,
      node: (key) => (
        <SkillMention
          key={key}
          live={context.live}
          skillId={skillId}
          text={text.slice(start, end)}
          workspaceId={context.workspaceId}
        />
      ),
    });
  }
  found.sort((a, b) => a.start - b.start);

  const nodes: ReactNode[] = [];
  let offset = 0;
  const pushText = (part: string) => {
    if (part)
      nodes.push(<span key={nodes.length}>{plainTextWithLinks(part) ?? part}</span>);
  };
  for (const mention of found) {
    pushText(text.slice(offset, mention.start));
    nodes.push(mention.node(nodes.length));
    offset = mention.end;
  }
  pushText(text.slice(offset));
  return nodes;
}

function MentionChip({ icon, label }: { icon: ReactNode; label: string }) {
  return (
    <span className="comma-chat-user-mention">
      <span aria-hidden className="comma-chat-user-mention-icon">
        {icon}
      </span>
      <span className="comma-chat-user-mention-label">{label}</span>
    </span>
  );
}

/** A tool by its own name and icon, a skill by its name; other `/words` stay as written. */
function SkillMention({
  live,
  skillId,
  text,
  workspaceId,
}: {
  live?: boolean | undefined;
  skillId: string;
  text: string;
  workspaceId: string;
}) {
  const skills = useWorkspaceSkills(live ? workspaceId : "");
  const skill = skills.find(
    (entry) => entry.skill_id.toLowerCase() === skillId.toLowerCase()
  );
  const tool = toolCommand(skill?.skill_id ?? skillId);
  if (tool) return <MentionChip icon={tool.icon} label={tool.label} />;
  if (!skill) return <span>{text}</span>;
  return <MentionChip icon={<CubeIcon className="size-4!" />} label={skill.name} />;
}

/** A person the message asked for a Task, by name and avatar: the avatar of a person the reader may still ask. */
function RequestMention({
  grantId,
  live,
  name,
  workspaceId,
}: {
  grantId: string;
  live?: boolean | undefined;
  name: string;
  workspaceId: string;
}) {
  const { value } = useTopic(
    live && workspaceId ? { topic: "taskRequests", prefer: workspaceId } : null
  );
  const owner = value?.targets?.find((target) => target.grant_id === grantId)?.workspace
    .owner;
  return (
    <MentionChip
      icon={
        <RequestPersonAvatar
          className="[&>img]:size-4! [&>span]:size-4! [&>span]:text-[8px]!"
          email={owner?.email}
          name={name}
          source={
            owner?.avatar_id
              ? { source: "target-avatar", grant: grantId, revision: owner.avatar_id }
              : undefined
          }
        />
      }
      label={name}
    />
  );
}

function ModelMention({
  live,
  modelId,
  name,
  workspaceId,
}: {
  live?: boolean | undefined;
  modelId: string;
  name: string;
  workspaceId: string;
}) {
  const { value } = useTopic(
    live && workspaceId ? { topic: "models", prefer: workspaceId } : null
  );
  const vendor = value?.models.find((model) => model.id === modelId)?.vendor;
  return (
    <MentionChip icon={<ModelVendorIcon tint vendor={vendor ?? ""} />} label={name} />
  );
}
