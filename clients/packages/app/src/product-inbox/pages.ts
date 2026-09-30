import type { ProductInboxItem, ProductInboxListResult } from "@comma/native-bridge";

export function refreshProductInboxPages(
  current: ProductInboxListResult[],
  firstPage: ProductInboxListResult
) {
  if (current.length === 0 || !sameProductInboxWorkspace(current[0]!, firstPage)) {
    return [firstPage];
  }

  if (
    (firstPage.source === "error" || firstPage.source === "unavailable") &&
    firstPage.items.length === 0
  ) {
    const retained = current.map(markProductInboxPageStale);
    retained[0] = {
      ...retained[0]!,
      ...firstPage,
      activeWorkspaceId: firstPage.activeWorkspaceId ?? retained[0]!.activeWorkspaceId,
      items: retained[0]!.items,
    };
    return retained;
  }

  if (current.length === 1) return [firstPage];

  const firstPageIds = new Set(firstPage.items.map((item) => item.id));
  const retainedTail = current.slice(1).map((page) => ({
    ...markProductInboxPageStale(page),
    items: page.items
      .filter((item) => !firstPageIds.has(item.id))
      .map(markProductInboxItemStale),
  }));
  return [firstPage, ...retainedTail];
}

export function appendProductInboxPages(
  current: ProductInboxListResult[],
  nextPage: ProductInboxListResult
) {
  if (current.length === 0 || !sameProductInboxWorkspace(current[0]!, nextPage)) {
    return [nextPage];
  }

  const nextIds = new Set(nextPage.items.map((item) => item.id));
  return [
    ...current.map((page) => ({
      ...page,
      items: page.items.filter((item) => !nextIds.has(item.id)),
    })),
    nextPage,
  ];
}

export function combineProductInboxPages(
  pages: ProductInboxListResult[]
): ProductInboxListResult | null {
  const firstPage = pages[0];
  const tailPage = pages.at(-1);
  if (!firstPage || !tailPage) return null;

  const {
    hasMore: _firstHasMore,
    nextCursor: _firstCursor,
    ...firstPageResult
  } = firstPage;
  return {
    ...firstPageResult,
    items: pages.flatMap((page) => page.items),
    ...(tailPage.hasMore === undefined ? {} : { hasMore: tailPage.hasMore === true }),
    ...(tailPage.hasMore === true && tailPage.nextCursor
      ? { nextCursor: tailPage.nextCursor }
      : {}),
    ...((firstPage.workspaces ?? tailPage.workspaces)
      ? { workspaces: firstPage.workspaces ?? tailPage.workspaces }
      : {}),
  };
}

function sameProductInboxWorkspace(
  left: ProductInboxListResult,
  right: ProductInboxListResult
) {
  const leftId = productInboxWorkspaceId(left);
  const rightId = productInboxWorkspaceId(right);
  return Boolean(leftId && rightId && leftId === rightId);
}

function productInboxWorkspaceId(result: ProductInboxListResult) {
  return result.activeWorkspaceId ?? result.items[0]?.workspaceId;
}

function markProductInboxPageStale(page: ProductInboxListResult) {
  return { ...page, items: page.items.map(markProductInboxItemStale) };
}

function markProductInboxItemStale(item: ProductInboxItem): ProductInboxItem {
  return { ...item, freshness: "stale" };
}
