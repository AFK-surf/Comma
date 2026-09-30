import { VelopackApp } from "velopack";

VelopackApp.build().run();

void bootstrapMain();

async function bootstrapMain() {
  await import("./main/index");
}
