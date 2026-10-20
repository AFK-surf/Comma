# Salix VM Gateway

The Cloudflare Worker starts, keeps alive, and stops Sandbox Containers.
Salix owns Group Workloads, billing, Devices, archive pointers, and Group Sandbox start and stop decisions.
The Container runs the Comma station. The station connects out to Salix `/v1/connect` with the server and Workload credential from the ensure request.
Nothing reaches the Container through the Worker.

Cloudflare stops a Container soon after its Durable Object becomes inactive.
Each ensure arms the SDK alarm that keeps the object active while its Container runs. Do not start a Container without it.

The Worker requires `x-salix-*` HMAC headers on internal routes.
The station exports its archive over its own connection directly to R2.
A wake's start names the archive with one signed URL of its part manifest. The Container entrypoint unpacks it from R2 before it starts the station.
A Cloudflare Sandbox backup is not the product archive.

## Release

Use the [Gateway release procedure](RELEASE.md). A full Container replacement can destroy a Group disk.
The instance type and limit for each environment are in [wrangler.jsonc](wrangler.jsonc).

## Local validation

```sh
npm test
npm run typecheck
```

Local checks do not prove the deployed Container image or a Group archive restore.
