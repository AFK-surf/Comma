import { useCommaMessages } from "@comma/i18n/react";
import { PageLoading } from "@comma/ui";

export function FilePreviewLoading() {
  const messages = useCommaMessages();
  return (
    <PageLoading
      data-testid="file-preview-loading"
      label={messages.file_preview_loading()}
    />
  );
}
