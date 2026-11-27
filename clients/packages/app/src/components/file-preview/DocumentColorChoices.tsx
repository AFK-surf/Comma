// The colours a reader gives text of a document: the choices of one kind of colour as a menu's rows, for the
// toolbar over a selection (`DocumentEditor`) and for a table's row or column (`DocumentTableControls`).
import { useCommaMessages } from "@comma/i18n/react";
import { CheckLargeIcon } from "@comma/ui/components/icons";
import { Menu, MenuItem, MenuSeparator } from "@comma/ui/components/menu";
import { Header, MenuSection } from "react-aria-components";
import { documentColors, type DocumentColor } from "./documentColors";

type Messages = ReturnType<typeof useCommaMessages>;

export const colorOf = (value: unknown): DocumentColor | "default" =>
  documentColors.find((color) => color === value) ?? "default";

/** A colour's name, as a reader's language says it. */
function colorName(messages: Messages, color: DocumentColor | "default") {
  switch (color) {
    case "gray":
      return messages.file_preview_document_color_gray();
    case "brown":
      return messages.file_preview_document_color_brown();
    case "orange":
      return messages.file_preview_document_color_orange();
    case "yellow":
      return messages.file_preview_document_color_yellow();
    case "green":
      return messages.file_preview_document_color_green();
    case "blue":
      return messages.file_preview_document_color_blue();
    case "purple":
      return messages.file_preview_document_color_purple();
    case "pink":
      return messages.file_preview_document_color_pink();
    case "red":
      return messages.file_preview_document_color_red();
    default:
      return messages.file_preview_document_color_default();
  }
}

const colorChoices = ["default", ...documentColors] as const;
export const colorCheck = <CheckLargeIcon className="size-xl text-fg-brand-primary" />;

/** One kind of colour as a list: the default first, then the palette, each with its swatch. */
export function ColorChoices({
  kind,
  label,
  current,
  onChoose,
}: {
  kind: "color" | "ground";
  label: string;
  /** The colour that is set, where one is: it is checked. */
  current?: DocumentColor | "default" | undefined;
  onChoose: (color: DocumentColor | "default") => void;
}) {
  const messages = useCommaMessages();
  return (
    <>
      <div className="px-xl pt-md pb-xs text-xs font-medium text-quaternary">
        {label}
      </div>
      <Menu
        aria-label={label}
        className="pb-sm"
        onAction={(key) => onChoose(colorOf(key))}
        variant="embedded"
      >
        {colorChoices.map((color) => (
          <MenuItem
            icon={
              <span
                className="comma-document-swatch"
                data-ink={kind === "color" ? color : undefined}
                data-wash={kind === "ground" ? color : undefined}
              >
                {kind === "color" ? "A" : null}
              </span>
            }
            id={color}
            key={color}
            shortcut={color === current ? colorCheck : undefined}
          >
            {kind === "color"
              ? messages.file_preview_document_color_text_item({
                  color: colorName(messages, color),
                })
              : messages.file_preview_document_color_ground_item({
                  color: colorName(messages, color),
                })}
          </MenuItem>
        ))}
      </Menu>
    </>
  );
}

/**
 * Both kinds of colour as one menu of two sections, for a menu that is another menu's own (a table's row or
 * column): a menu beside a menu is one list.
 */
export function ColorMenu({
  label,
  onChoose,
}: {
  label: string;
  onChoose: (kind: "color" | "ground", color: DocumentColor | "default") => void;
}) {
  const messages = useCommaMessages();
  // A heading sits in the column of the rows below it.
  const header = "mx-sm px-md pt-sm pb-xs text-xs font-medium text-quaternary";
  const section = (kind: "color" | "ground", name: string) => (
    <MenuSection>
      <Header className={header}>{name}</Header>
      {colorChoices.map((color) => (
        <MenuItem
          icon={
            <span
              className="comma-document-swatch"
              data-ink={kind === "color" ? color : undefined}
              data-wash={kind === "ground" ? color : undefined}
            >
              {kind === "color" ? "A" : null}
            </span>
          }
          id={`${kind}:${color}`}
          key={color}
        >
          {kind === "color"
            ? messages.file_preview_document_color_text_item({
                color: colorName(messages, color),
              })
            : messages.file_preview_document_color_ground_item({
                color: colorName(messages, color),
              })}
        </MenuItem>
      ))}
    </MenuSection>
  );
  return (
    <Menu
      aria-label={label}
      className="py-sm"
      onAction={(key) => {
        const [kind, color] = String(key).split(":");
        onChoose(kind === "ground" ? "ground" : "color", colorOf(color));
      }}
      variant="embedded"
    >
      {section("color", messages.file_preview_document_color_text())}
      <MenuSeparator />
      {section("ground", messages.file_preview_document_color_ground())}
    </Menu>
  );
}
