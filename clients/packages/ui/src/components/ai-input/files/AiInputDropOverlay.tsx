import { FileIcon, ImageIcon, VideoIcon } from "../../icons";
import {
  aiInputDropOverlay,
  aiInputDropOverlayCopy,
  aiInputDropOverlayIcon,
  aiInputDropOverlayIcons,
  aiInputDropOverlaySubtitle,
  aiInputDropOverlayTitle,
  aiInputDropOverlayWash,
} from "../styles";

const dropTypeIcons = [FileIcon, ImageIcon, VideoIcon] as const;

export const AiInputDropOverlay = ({
  active,
  subtitle,
  title,
}: {
  active: boolean;
  subtitle: string;
  title: string;
}) => (
  <output
    aria-hidden={active ? undefined : true}
    aria-live={active ? "polite" : undefined}
    className={aiInputDropOverlay}
    data-drop-active={active ? "true" : undefined}
    data-testid="ai-input-drop-overlay"
  >
    <div aria-hidden className={aiInputDropOverlayIcons}>
      {dropTypeIcons.map((Icon, index) => (
        <span
          className={aiInputDropOverlayIcon}
          key={Icon.displayName ?? index}
          style={{ zIndex: index }}
        >
          <Icon className="size-5" />
        </span>
      ))}
    </div>
    <div aria-hidden className={aiInputDropOverlayWash} />
    <div className={aiInputDropOverlayCopy}>
      <p className={aiInputDropOverlayTitle}>{title}</p>
      <p className={aiInputDropOverlaySubtitle}>{subtitle}</p>
    </div>
  </output>
);
