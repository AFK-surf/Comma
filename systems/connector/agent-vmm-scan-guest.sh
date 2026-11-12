#!/usr/bin/env bash
set -euo pipefail

# Scan the selected release payload once, including its embedded OCI images.
rootfs="$(cd -- "$1" && pwd)"
status=0
docker run --rm \
  --user "$(id -u):$(id -g)" \
  --read-only --cap-drop ALL --security-opt no-new-privileges \
  --tmpfs /tmp:rw,mode=1777 \
  --mount "type=bind,src=$rootfs,dst=/guest,readonly" \
  --env TRIVY_CACHE_DIR=/tmp/trivy-cache \
  --entrypoint sh \
  docker.io/aquasec/trivy@sha256:bcc376de8d77cfe086a917230e818dc9f8528e3c852f7b1aff648949b6258d1c \
  -eu -c '
    set -- --scanners vuln --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1
    status=0
    trivy rootfs "$@" /guest || status=1
    # An .oci.tar is an OCI layout in a tar. Trivy reads a layout only as a
    # directory, so each archive is unpacked first.
    for archive in /guest/usr/lib/agent-vmm/*.oci.tar; do
      [ -f "$archive" ] || continue
      layout="$(mktemp -d)"
      if tar -xf "$archive" -C "$layout"; then
        trivy image "$@" --skip-db-update --input "$layout" || status=1
      else
        status=1
      fi
      rm -rf "$layout"
    done
    exit "$status"
  ' || status=$?
if [ "$status" -ne 0 ]; then
  echo '::warning::Guest scan found vulnerabilities or did not complete. See the scan logs. Publication is not blocked.'
fi
exit "$status"
