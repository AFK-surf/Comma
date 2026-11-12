import { arch, platform } from "node:process";

/** The platform and architecture the native parts are built for (cross/macos sets them on Linux). */
export const targetPlatform = process.env.COMMA_TARGET_PLATFORM ?? platform;
export const targetArch = process.env.COMMA_TARGET_ARCH ?? arch;
export const crossCompilingMacOS = targetPlatform === "darwin" && platform !== "darwin";
