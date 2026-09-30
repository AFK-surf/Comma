/* oxlint-disable jsx-a11y/prefer-tag-over-role -- custom combobox popup uses ARIA listbox/option semantics while keeping button mouse affordances. */
import { useCommaMessages } from "@comma/i18n/react";
import type { CommaSkill } from "../../../api";

export function SkillMentionMenu({
  activeIndex,
  onHover,
  onSelect,
  skills,
}: {
  activeIndex: number;
  onHover: (index: number) => void;
  onSelect: (skill: CommaSkill) => void;
  skills: CommaSkill[];
}) {
  const messages = useCommaMessages();

  if (skills.length === 0) {
    return null;
  }

  return (
    <div
      aria-label={messages.chat_skill_menu()}
      className="comma-chat-skill-menu"
      role="listbox"
    >
      {skills.map((skill, index) => (
        <button
          aria-selected={index === activeIndex}
          className="comma-chat-skill-option"
          key={skill.location}
          onMouseDown={(event) => {
            event.preventDefault();
            onSelect(skill);
          }}
          onMouseEnter={() => onHover(index)}
          role="option"
          type="button"
        >
          <span className="comma-chat-skill-name">{skill.name}</span>
          <span className="comma-chat-skill-description">
            {skill.description || skill.location}
          </span>
        </button>
      ))}
    </div>
  );
}
