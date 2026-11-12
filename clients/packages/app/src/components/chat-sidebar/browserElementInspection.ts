import type { BrowserSidebarInspectResult } from "@comma/native-bridge";
import {
  pictureDataUrl,
  type ChatDraftSelection,
} from "../chat/composer/draftSelections";

type SelectedInspection = Extract<BrowserSidebarInspectResult, { status: "selected" }>;

/**
 * An element picked on a page, with what the person wrote about it, as a selection for the chat's next message: the
 * chat's composer shows it as a tile, and the message carries its note, its screenshot and its DOM context
 * (`composeMessageWithSelections`). An element that was not on screen has no picture.
 */
export function browserElementSelection(
  inspection: SelectedInspection
): Omit<ChatDraftSelection, "id"> {
  const { screenshot } = inspection;
  return {
    note: inspection.userMessage.trim(),
    ...(screenshot
      ? {
          picture: { bytes: screenshot, type: "image/png" as const },
          thumbnail: pictureDataUrl(screenshot, "image/png"),
        }
      : {}),
    about: {
      kind: "element",
      inspectionId: inspection.inspectionId,
      page: inspection.page,
      element: inspection.element,
    },
  };
}
