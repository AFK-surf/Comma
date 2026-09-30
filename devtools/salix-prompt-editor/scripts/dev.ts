const backend = Bun.spawn({
  cmd: ["bun", "--watch", "server/index.ts"],
  cwd: new URL("..", import.meta.url).pathname,
  stdin: "inherit",
  stdout: "inherit",
  stderr: "inherit",
});

const frontend = Bun.spawn({
  cmd: ["bunx", "vite", "--host", "127.0.0.1"],
  cwd: new URL("..", import.meta.url).pathname,
  stdin: "inherit",
  stdout: "inherit",
  stderr: "inherit",
});

const stop = () => {
  backend.kill();
  frontend.kill();
};

process.on("SIGINT", stop);
process.on("SIGTERM", stop);

await Promise.race([backend.exited, frontend.exited]);
stop();
