// The upstream minio/minio and minio/mc images are no longer published. The
// tests run the storage release that selfhost/Storage.Dockerfile builds:
//
//   docker build -f selfhost/Storage.Dockerfile --target minio -t comma-ci-minio:local selfhost
//   docker build -f selfhost/Storage.Dockerfile --target mc -t comma-ci-mc:local selfhost
export const MINIO_IMAGE = process.env.SALIX_E2E_MINIO_IMAGE ??
  "comma-ci-minio:local";
export const MC_IMAGE = process.env.SALIX_E2E_MC_IMAGE ??
  "comma-ci-mc:local";

// `docker` arguments that create `bucket` in the MinIO container `container`.
export function createBucketArgs(container: string, bucket: string): string[] {
  return [
    "run",
    "--rm",
    "--network",
    `container:${container}`,
    "--entrypoint",
    "/bin/sh",
    MC_IMAGE,
    "-c",
    `mc alias set local http://127.0.0.1:9000 minioadmin minioadmin >/dev/null && mc mb -p local/${bucket}`,
  ];
}
