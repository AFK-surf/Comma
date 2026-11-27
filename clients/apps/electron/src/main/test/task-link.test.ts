import { describe, expect, it } from "vitest";
import { taskLinkRoute } from "../task-link";

describe("Task deep link", () => {
  it("opens the Task route only for this app's scheme and well-formed ids", () => {
    expect(
      taskLinkRoute("comma://task?workspace=wsp_1&group=grp1_2_3&task=cnv_4", "comma")
    ).toBe("/tasks/wsp_1/grp1_2_3/cnv_4");
    expect(
      taskLinkRoute(
        "comma-staging://task/?workspace=wsp_1&group=grp1_2_3&task=cnv_4",
        "comma-staging"
      )
    ).toBe("/tasks/wsp_1/grp1_2_3/cnv_4");

    for (const url of [
      "comma://task?workspace=wsp_1&group=grp1_2_3&task=cnv_4",
      "https://task?workspace=wsp_1&group=grp1_2_3&task=cnv_4",
      "comma-staging://tasks?workspace=wsp_1&group=grp1_2_3&task=cnv_4",
      "comma-staging://task/extra?workspace=wsp_1&group=grp1_2_3&task=cnv_4",
      "comma-staging://user@task?workspace=wsp_1&group=grp1_2_3&task=cnv_4",
      "comma-staging://task:80?workspace=wsp_1&group=grp1_2_3&task=cnv_4",
      "comma-staging://task?workspace=wsp_1&group=grp1_2_3&task=cnv_4#frag",
      "comma-staging://task?workspace=wsp_1&group=grp1_2_3",
      "comma-staging://task?workspace=wsp_1&task=cnv_4",
      "comma-staging://task?group=grp1_2_3&task=cnv_4",
      "comma-staging://task?workspace=..&group=grp1_2_3&task=cnv_4",
      "comma-staging://task?workspace=wsp_1/evil&group=grp1_2_3&task=cnv_4",
      `comma-staging://task?workspace=${"a".repeat(257)}&group=grp1_2_3&task=cnv_4`,
      "not a url",
    ]) {
      expect(taskLinkRoute(url, "comma-staging")).toBeUndefined();
    }
  });
});
