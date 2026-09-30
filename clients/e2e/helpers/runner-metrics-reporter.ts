import { cpus, freemem, loadavg, platform, totalmem } from "node:os";
import { execFileSync } from "node:child_process";
import type {
  Reporter,
  TestCase,
  TestResult,
  TestStep,
} from "@playwright/test/reporter";

export default class RunnerMetricsReporter implements Reporter {
  private timer: ReturnType<typeof setInterval> | undefined;
  private samples: Array<{ seconds: number; load: number[]; freeMiB: number }> = [];
  private started = 0;
  private operations = new Map<string, { calls: number; totalMs: number }>();

  onStepEnd(_test: TestCase, _result: TestResult, step: TestStep) {
    if (step.category !== "pw:api" && step.category !== "expect") return;
    // Aggregate fixed operation names only, never locator text or test data.
    const operation =
      step.category === "expect"
        ? "assertion"
        : /screenshot/i.test(step.title)
          ? "screenshot"
          : /goto|navigate/i.test(step.title)
            ? "navigation"
            : /click/i.test(step.title)
              ? "click"
              : /waitFor|^wait /i.test(step.title)
                ? "wait"
                : /evaluate/i.test(step.title)
                  ? "evaluate"
                  : "other-api";
    const sample = this.operations.get(operation) ?? { calls: 0, totalMs: 0 };
    sample.calls += 1;
    sample.totalMs += step.duration;
    this.operations.set(operation, sample);
  }

  onBegin() {
    this.started = performance.now();
    console.log(
      "E2E runner capacity " +
        JSON.stringify({
          platform: platform(),
          cpuCount: cpus().length,
          cpuModel: cpus()[0]?.model,
          totalMiB: Math.round(totalmem() / 1024 ** 2),
          swap: this.swapUsage(),
        })
    );
    this.sample();
    this.timer = setInterval(() => this.sample(), 30_000);
    this.timer.unref();
  }

  onEnd() {
    clearInterval(this.timer);
    this.sample();
    // Aggregate step time can overlap across workers and nested assertions.
    console.log(
      "E2E operation totals " + JSON.stringify(Object.fromEntries(this.operations))
    );
    console.log(
      "E2E runner samples " +
        JSON.stringify({ samples: this.samples, finalSwap: this.swapUsage() })
    );
  }

  private sample() {
    this.samples.push({
      seconds: Math.round((performance.now() - this.started) / 1000),
      load: loadavg().map((value) => Math.round(value * 100) / 100),
      freeMiB: Math.round(freemem() / 1024 ** 2),
    });
  }

  private swapUsage() {
    if (platform() !== "darwin") return undefined;
    try {
      return execFileSync("/usr/sbin/sysctl", ["vm.swapusage"], {
        encoding: "utf8",
        timeout: 2000,
      }).trim();
    } catch {
      return "unavailable";
    }
  }
}
