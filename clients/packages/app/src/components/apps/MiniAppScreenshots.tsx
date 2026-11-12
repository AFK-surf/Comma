import type { MiniAppVia } from "@comma/core-client";
import { ScrollArea } from "@comma/ui/components/scroll-area";
import { useMiniAppImage } from "./miniAppIcon";

function Screenshot({
  url,
  via,
  name,
  index,
}: {
  url: string;
  via: MiniAppVia;
  name: string;
  index: number;
}) {
  const src = useMiniAppImage(url, via, true);
  return src ? (
    <img
      src={src}
      alt={`${name} · ${index + 1}`}
      className="h-60 w-auto shrink-0 rounded-xl object-contain"
    />
  ) : null;
}

/** Only the selected app reads its ordered Version screenshots. */
export function MiniAppScreenshots({
  urls,
  via,
  name,
}: {
  urls: readonly string[] | undefined;
  via: MiniAppVia;
  name: string;
}) {
  if (!urls?.length) return null;
  return (
    <ScrollArea orientation="horizontal" className="w-full min-w-0">
      <div className="flex gap-lg p-lg">
        {urls.slice(0, 6).map((url, index) => (
          <Screenshot key={url} url={url} via={via} name={name} index={index} />
        ))}
      </div>
    </ScrollArea>
  );
}
