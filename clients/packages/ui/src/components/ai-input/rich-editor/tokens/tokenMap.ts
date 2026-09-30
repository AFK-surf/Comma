import type { AiInputRichTokenSegment, AiInputRichValue } from "../../richText";

export function syncTokenMap(
  value: AiInputRichValue,
  tokenMap: Map<string, AiInputRichTokenSegment>
) {
  tokenMap.clear();
  value.tokens.forEach((token) => tokenMap.set(token.instanceId, token));
}

export function nextTokenInstanceId(
  menuId: string,
  itemId: string,
  counter: { current: number },
  tokenMap: Map<string, AiInputRichTokenSegment>
) {
  let instanceId: string;
  do {
    instanceId = `${menuId}-${itemId}-${++counter.current}`;
  } while (tokenMap.has(instanceId));
  return instanceId;
}

export function pruneTokenMap(
  value: AiInputRichValue,
  tokenMap: Map<string, AiInputRichTokenSegment>
) {
  const remaining = new Set(value.tokens.map((token) => token.instanceId));
  tokenMap.forEach((_token, id) => {
    if (!remaining.has(id)) tokenMap.delete(id);
  });
}
