# Salix VM Gateway

The Cloudflare Worker manages Sandbox lifecycle and proxies signed requests to
the Container. Salix owns Group Workloads, billing, Devices, archive pointers,
and Group Sandbox start and stop decisions. The Container runs the shared
`salix-runtime-agent`.

The Worker requires `x-salix-*` HMAC headers on internal routes. It bounds
request bodies before proxying them. The Connector owns archive export,
import, and completion receipts. Salix stores durable archive chunks in S3.
A Cloudflare Sandbox backup is not the product archive.

## Release

Use the [Gateway release procedure](RELEASE.md). Normal Comma Deployment starts
the Gateway image job after the mainline Comma release. The job replaces a
Container image when tracked Connector or Container runtime sources change.
A Worker-only change uses a per-VM candidate rollout.

A full Container replacement can destroy a Group disk. The image job fences
new starts, archives running Group Containers, checks unsettled starts and
instance ownership, then deploys and probes a fresh Connector. The Gateway
Worker itself has no business disk to archive.

The instance type and limit for each environment are in [wrangler.jsonc](wrangler.jsonc).
Instances consume resources while they run. Salix releases idle keepAlive
leases after it archives the Group disk.

## Local validation

```sh
npm test
npm run typecheck
```

Local checks do not prove the deployed Container image or a Group archive
restore. The release job verifies the image; test a specific Group restore
when that Group's retained data is being migrated or repaired.
