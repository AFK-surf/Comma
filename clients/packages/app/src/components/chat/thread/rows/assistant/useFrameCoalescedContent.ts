import { useLayoutEffect, useRef, useState } from "react";

export function useFrameCoalescedContent(content: string, activelyStreaming: boolean) {
  const [renderedContent, setRenderedContent] = useState(content);
  const renderedContentRef = useRef(content);
  const latestContentRef = useRef(content);
  const frameRef = useRef<number | undefined>(undefined);
  const renderImmediately =
    !activelyStreaming ||
    renderedContentRef.current.length === 0 ||
    content.length <= renderedContentRef.current.length ||
    typeof document === "undefined" ||
    document.visibilityState !== "visible";

  useLayoutEffect(() => {
    latestContentRef.current = content;
    if (content === renderedContentRef.current) return;

    if (renderImmediately) {
      if (frameRef.current !== undefined) {
        window.cancelAnimationFrame(frameRef.current);
        frameRef.current = undefined;
      }
      renderedContentRef.current = content;
      setRenderedContent((current) => (current === content ? current : content));
      return;
    }

    // This is scheduled only by an accepted stream update. It coalesces a
    // burst into one Markdown render per frame; it is not a polling loop.
    if (frameRef.current !== undefined) return;
    frameRef.current = window.requestAnimationFrame(() => {
      frameRef.current = undefined;
      const nextContent = latestContentRef.current;
      renderedContentRef.current = nextContent;
      setRenderedContent((current) =>
        current === nextContent ? current : nextContent
      );
    });
  }, [content, renderImmediately]);

  useLayoutEffect(
    () => () => {
      if (frameRef.current !== undefined) {
        window.cancelAnimationFrame(frameRef.current);
        frameRef.current = undefined;
      }
    },
    []
  );

  return renderImmediately ? content : renderedContent;
}
