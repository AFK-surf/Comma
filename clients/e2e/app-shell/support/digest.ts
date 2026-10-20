// One frame of a test's execution record (./record), in the test's page: what
// the page shows — the DOM, every animation's state and time, every element's
// box — as a short hash, and in full to find where two runs part.

export function frameState() {
  const animations: string[] = [];
  for (const animation of document.getAnimations()) {
    const name =
      (animation as CSSTransition).transitionProperty ??
      (animation as CSSAnimation).animationName ??
      animation.id;
    const time =
      animation.currentTime === null
        ? "null"
        : String(Math.round(Number(animation.currentTime) * 1000) / 1000);
    const target = (animation.effect as KeyframeEffect | null)?.target;
    const owner = target
      ? `${target.tagName.toLowerCase()}${target.getAttribute("data-slot") ? `[data-slot=${target.getAttribute("data-slot")}]` : ""}.${(target.getAttribute("class") ?? "").split(" ")[0]}`
      : "";
    animations.push(`${name}:${animation.playState}:${time} ${owner}`);
  }
  const boxes: string[] = [];
  for (const element of document.body.querySelectorAll("*")) {
    const box = element.getBoundingClientRect();
    boxes.push(`${element.tagName} ${box.x},${box.y},${box.width},${box.height}`);
  }
  // An object URL's name is the browser's random one: the record names each
  // by the order it first shows.
  const objectUrls = new Map<string, string>();
  const html = document.body.innerHTML.replaceAll(/blob:[^"'\s)]+/g, (url) => {
    if (!objectUrls.has(url)) objectUrls.set(url, `blob:${objectUrls.size + 1}`);
    return objectUrls.get(url)!;
  });
  return { html, animations, boxes };
}
