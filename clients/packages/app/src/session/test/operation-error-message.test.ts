import { describe, expect, it } from "vitest";
import {
  SessionOperationDisplayError,
  sessionOperationDisplayError,
} from "../operation-error-message";

describe("sessionOperationDisplayError", () => {
  it("localizes authentication failures", () => {
    expect(
      sessionOperationDisplayError("invalid_challenge", "Unsupported").message
    ).toBe("That verification code is invalid. Please try again.");
    expect(
      sessionOperationDisplayError("invalid_challenge", "不支持此操作", "zh-CN").message
    ).toBe("验证码无效，请重试。");
  });

  it("keeps the host-specific unsupported message", () => {
    expect(
      sessionOperationDisplayError("unsupported", "此环境不支持登录", "zh-CN").message
    ).toBe("此环境不支持登录");
  });

  it("preserves the operation code for recovery decisions", () => {
    const error = sessionOperationDisplayError("network_unavailable", "Unsupported");

    expect(error).toBeInstanceOf(SessionOperationDisplayError);
    expect((error as SessionOperationDisplayError).code).toBe("network_unavailable");
  });
});
