import type { DraftMap } from "./editor";

const STORAGE_KEY = "salix-prompt-atlas:drafts:v1";

type StoredDrafts = {
  catalogVersion: string;
  drafts: DraftMap;
};

export function loadDrafts(): StoredDrafts | null {
  try {
    const value = localStorage.getItem(STORAGE_KEY);
    return value ? (JSON.parse(value) as StoredDrafts) : null;
  } catch {
    return null;
  }
}

export function saveDrafts(catalogVersion: string, drafts: DraftMap): void {
  localStorage.setItem(
    STORAGE_KEY,
    JSON.stringify({ catalogVersion, drafts } satisfies StoredDrafts),
  );
}

export function clearStoredDrafts(): void {
  localStorage.removeItem(STORAGE_KEY);
}
