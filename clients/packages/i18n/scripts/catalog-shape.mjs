function controlStrings(value) {
  if (typeof value === "string") {
    return [value.trim().replace(/\s+/g, " ")];
  }
  if (Array.isArray(value)) {
    return value.flatMap(controlStrings);
  }
  return [];
}

export function selectorShape(value) {
  if (Array.isArray(value)) return value.flatMap(selectorShape);
  if (!value || typeof value !== "object") return [];

  return Object.entries(value).flatMap(([name, child]) => {
    if (name === "match" && child && typeof child === "object") {
      return [name, ...Object.keys(child).toSorted()];
    }
    if (name === "declarations" || name === "selectors") {
      return [name, ...controlStrings(child).map((text) => `${name}:${text}`)];
    }
    return [name, ...selectorShape(child)];
  });
}
