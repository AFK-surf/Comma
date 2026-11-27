import { expect, it } from "vitest";
import { localDirectory } from "../fileIntake";

it("names the whole folder a file is in, the home folder as ~", () => {
  expect(localDirectory("/Users/me/Downloads/project-assets.zip")).toBe("~/Downloads");
  expect(localDirectory("/home/me/Desktop/podcast.mp3")).toBe("~/Desktop");
  expect(localDirectory("/Users/me/podcast.mp3")).toBe("~/");
  expect(localDirectory("/podcast.mp3")).toBe("/");
  expect(localDirectory("/Volumes/Media/clip.mov")).toBe("/Volumes/Media");
  expect(localDirectory("C:\\Users\\me\\Downloads\\podcast.mp3")).toBe("~\\Downloads");
  expect(localDirectory("D:\\clip.mov")).toBe("D:\\");
  expect(localDirectory("/Users/me/Workspace/AFK-surf/Cue/scripts/run.py")).toBe(
    "~/Workspace/AFK-surf/Cue/scripts"
  );
});
