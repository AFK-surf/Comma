import { afterEach, describe, expect, it, vi } from "vitest";
import {
  CommaApiError,
  type CommaApiClient,
  type CommaRecommendationLinkPreview,
} from "../../../api";
import {
  hasRecommendationLinkPreview,
  loadRecommendationLinkPreview,
  peekRecommendationLinkPreview,
  resetRecommendationLinkPreviewCacheForTests,
} from "../linkPreviewCache";

const preview: CommaRecommendationLinkPreview = {
  additions: 1,
  author: null,
  changedFiles: 1,
  deletions: 0,
  href: "https://github.com/AFK-surf/Comma/pull/845",
  kind: "github_pull_request",
  number: 845,
  repository: "AFK-surf/Comma",
  state: "open",
  title: "PR",
  updatedAt: null,
};
const link = {
  href: "https://github.com/AFK-surf/Comma/pull/845",
  sourceId: "github-account",
};

afterEach(() => {
  resetRecommendationLinkPreviewCacheForTests();
});

describe("hasRecommendationLinkPreview", () => {
  it("matches the server's rich link shapes and never Gmail", () => {
    for (const href of [
      "https://github.com/AFK-surf/Comma/pull/845",
      "https://github.com/AFK-surf/Comma/pull/845/files?x=1",
      "https://linear.app/comma/issue/COMMA-143",
      "https://linear.app/comma/issue/COMMA-143/fix-onboarding-crash",
      "https://www.notion.so/comma/Q3-plan-4b8e7d0d9f1a4ed89d6ba8d11080a812",
      "https://notion.so/4b8e7d0d9f1a4ed89d6ba8d11080a812?pvs=4",
      "https://www.google.com/calendar/event?eid=ZXZ0MTIzIHphbndlaUBjb21tYS5sb2NhbA",
      "https://calendar.google.com/calendar/u/0/r/eventedit/ZXZ0MTIzIHphbndlaUBjb21tYS5sb2NhbA",
      "https://comma-local.slack.com/archives/C01234567/p1786900000000000",
      "https://comma-local.slack.com/archives/C01234567/p1786900000000000?thread_ts=1786900000.000200&cid=C01234567",
      "https://docs.google.com/document/d/comma-local-launch-brief/edit",
      "https://docs.google.com/spreadsheets/d/1AbC_dEf-9/edit#gid=0",
      "https://docs.google.com/presentation/d/1AbC_dEf-9/edit?usp=sharing",
      "https://docs.google.com/forms/d/1AbC_dEf-9/viewform",
      "https://drive.google.com/file/d/1AbC_dEf-9/view?usp=sharing",
      "https://drive.google.com/open?id=1AbC_dEf-9",
      "https://drive.google.com/open?usp=drive_link&id=1AbC_dEf-9",
    ]) {
      expect(hasRecommendationLinkPreview(href), href).toBe(true);
    }
    for (const href of [
      "https://github.com/AFK-surf/Comma/issues/845",
      "http://github.com/AFK-surf/Comma/pull/845",
      "https://mail.google.com/mail/#all/198f2ab4c7d3e011",
      "https://calendar.google.com",
      "http://comma-local.slack.com/archives/C01234567/p1786900000000000",
      "https://comma-local.slack.com/archives/C01234567",
      "http://drive.google.com/file/d/1AbC_dEf-9/view",
      "https://drive.google.com/drive/folders/1AbC_dEf-9",
      // Published-form/spreadsheet URLs put a pseudo segment after /d/ — the
      // "e" must not pass as a drive file id (ids demand >= 10 chars).
      "https://docs.google.com/forms/d/e/1FAIpQLSfAbCdEf/viewform",
      "https://docs.google.com/spreadsheets/d/e/2PACX-1vRabc/pubhtml",
    ]) {
      expect(hasRecommendationLinkPreview(href), href).toBe(false);
    }
  });
});

describe("loadRecommendationLinkPreview", () => {
  it("dedupes concurrent reads and serves the cached preview afterwards", async () => {
    const api = {
      getRecommendationLinkPreview: vi.fn().mockResolvedValue(preview),
    } as unknown as CommaApiClient;

    const [first, second] = await Promise.all([
      loadRecommendationLinkPreview(api, "wsp_1", link),
      loadRecommendationLinkPreview(api, "wsp_1", link),
    ]);
    await expect(loadRecommendationLinkPreview(api, "wsp_1", link)).resolves.toBe(
      preview
    );

    expect(first).toBe(preview);
    expect(second).toBe(preview);
    expect(api.getRecommendationLinkPreview).toHaveBeenCalledTimes(1);
    expect(api.getRecommendationLinkPreview).toHaveBeenCalledWith("wsp_1", link);
  });

  it("remembers other failures briefly, then retries", async () => {
    vi.useFakeTimers();
    try {
      const api = {
        getRecommendationLinkPreview: vi
          .fn()
          .mockRejectedValueOnce(new Error("boom"))
          .mockResolvedValueOnce(preview),
      } as unknown as CommaApiClient;

      await expect(loadRecommendationLinkPreview(api, "wsp_1", link)).rejects.toThrow(
        "boom"
      );
      expect(peekRecommendationLinkPreview(api, "wsp_1", link)).toBe("missing");
      await expect(loadRecommendationLinkPreview(api, "wsp_1", link)).rejects.toThrow(
        "boom"
      );
      vi.advanceTimersByTime(60_000 + 1);
      await expect(loadRecommendationLinkPreview(api, "wsp_1", link)).resolves.toBe(
        preview
      );
      expect(api.getRecommendationLinkPreview).toHaveBeenCalledTimes(2);
    } finally {
      vi.useRealTimers();
    }
  });

  it("remembers a provider failure (503) for a minute, not the full TTL", async () => {
    vi.useFakeTimers();
    try {
      const api = {
        getRecommendationLinkPreview: vi
          .fn()
          .mockRejectedValue(new CommaApiError(503, "workspace_unavailable")),
      } as unknown as CommaApiClient;

      await expect(loadRecommendationLinkPreview(api, "wsp_1", link)).rejects.toThrow();
      vi.advanceTimersByTime(59_000);
      expect(peekRecommendationLinkPreview(api, "wsp_1", link)).toBe("missing");
      vi.advanceTimersByTime(2_000);
      expect(peekRecommendationLinkPreview(api, "wsp_1", link)).toBeUndefined();
    } finally {
      vi.useRealTimers();
    }
  });

  it("remembers a 404 so the next hover settles without a request", async () => {
    const missing = new CommaApiError(404, "not_found");
    const api = {
      getRecommendationLinkPreview: vi.fn().mockRejectedValue(missing),
    } as unknown as CommaApiClient;

    expect(peekRecommendationLinkPreview(api, "wsp_1", link)).toBeUndefined();
    await expect(loadRecommendationLinkPreview(api, "wsp_1", link)).rejects.toBe(
      missing
    );
    expect(peekRecommendationLinkPreview(api, "wsp_1", link)).toBe("missing");
    await expect(loadRecommendationLinkPreview(api, "wsp_1", link)).rejects.toBe(
      missing
    );
    expect(api.getRecommendationLinkPreview).toHaveBeenCalledTimes(1);
  });

  it("re-reads a remembered 404 once it expires", async () => {
    vi.useFakeTimers();
    try {
      const api = {
        getRecommendationLinkPreview: vi
          .fn()
          .mockRejectedValueOnce(new CommaApiError(404, "not_found"))
          .mockResolvedValueOnce(preview),
      } as unknown as CommaApiClient;

      await expect(loadRecommendationLinkPreview(api, "wsp_1", link)).rejects.toThrow();
      vi.advanceTimersByTime(5 * 60_000 + 1);
      expect(peekRecommendationLinkPreview(api, "wsp_1", link)).toBeUndefined();
      await expect(loadRecommendationLinkPreview(api, "wsp_1", link)).resolves.toBe(
        preview
      );
      expect(peekRecommendationLinkPreview(api, "wsp_1", link)).toBe(preview);
      expect(api.getRecommendationLinkPreview).toHaveBeenCalledTimes(2);
    } finally {
      vi.useRealTimers();
    }
  });

  it("omits an absent sourceId from the request", async () => {
    const api = {
      getRecommendationLinkPreview: vi.fn().mockResolvedValue(preview),
    } as unknown as CommaApiClient;

    await loadRecommendationLinkPreview(api, "wsp_1", { href: link.href });
    expect(api.getRecommendationLinkPreview).toHaveBeenCalledWith("wsp_1", {
      href: link.href,
    });
  });
});
