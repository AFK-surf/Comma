#!/usr/bin/env bash
set -euo pipefail

container="comma-release-k3s-e2e-${PPID}"
namespace="comma-release-e2e-${PPID}"
workspace="$(mktemp -d)"
kubeconfig="${workspace}/kubeconfig"
helm_bin="${COMMA_HELM_BIN:-}"

if [[ -z "${helm_bin}" ]]; then
  os=$(uname -s | tr '[:upper:]' '[:lower:]')
  arch=$(uname -m)
  case "${arch}" in
    x86_64) arch=amd64 ;;
    arm64|aarch64) arch=arm64 ;;
    *) echo "unsupported Helm test architecture: ${arch}" >&2; exit 1 ;;
  esac
  case "${os}-${arch}" in
    darwin-arm64) helm_sha=5410a0dae3d5d91f45653b161260d9301aabc4ae80ae50a6605d66884b6df8ea ;;
    darwin-amd64) helm_sha=10c1e36ee8c5f2e2ee25a16599cb03ab74c0953cd889cacb980a49ba4b6574ba ;;
    linux-amd64) helm_sha=9adafecab4d406853bba163a70e9f104f47dbbf65ce24b7653bae7e36150bcb6 ;;
    linux-arm64) helm_sha=78803142087a0069fa4b50d3f32a84d3ef25c14d1ee8a40fbccf86a6216d2f36 ;;
    *) echo "unsupported Helm test platform: ${os}-${arch}" >&2; exit 1 ;;
  esac
  helm_archive="${workspace}/helm.tar.gz"
  curl --fail --silent --show-error --location \
    "https://get.helm.sh/helm-v4.2.2-${os}-${arch}.tar.gz" --output "${helm_archive}"
  if [[ "${os}" == darwin ]]; then
    echo "${helm_sha}  ${helm_archive}" | shasum -a 256 --check
  else
    echo "${helm_sha}  ${helm_archive}" | sha256sum --check --strict
  fi
  tar -xzf "${helm_archive}" -C "${workspace}"
  helm_bin="${workspace}/${os}-${arch}/helm"
fi

cleanup() {
  if [[ -f "${kubeconfig}" ]]; then
    KUBECONFIG="${kubeconfig}" kubectl delete namespace "${namespace}" --ignore-not-found=true --wait=false >/dev/null 2>&1 || true
  fi
  docker rm -f "${container}" >/dev/null 2>&1 || true
  rm -rf "${workspace}"
}
trap cleanup EXIT

docker run --detach --privileged --name "${container}" \
  --publish 127.0.0.1::6443 \
  rancher/k3s:v1.35.5-k3s1 server \
  --disable=traefik --disable=servicelb --tls-san=127.0.0.1 >/dev/null

for _ in $(seq 1 90); do
  if docker exec "${container}" kubectl get --raw=/readyz >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
docker exec "${container}" kubectl get --raw=/readyz >/dev/null

docker cp "${container}:/etc/rancher/k3s/k3s.yaml" "${kubeconfig}" >/dev/null
endpoint="$(docker port "${container}" 6443/tcp)"
sed -i.bak "s#127.0.0.1:6443#${endpoint}#" "${kubeconfig}"

KUBECONFIG="${kubeconfig}" kubectl create namespace "${namespace}" >/dev/null
KUBECONFIG="${kubeconfig}" python3 k8s/comma/chart/test_proxy_lifecycle.py \
  --context default --helm "${helm_bin}"
KUBECONFIG="${kubeconfig}" python3 k8s/comma/chart/test_scheduling.py \
  --context default --helm "${helm_bin}"
KUBECONFIG="${kubeconfig}" \
  COMMA_RELEASE_KUBERNETES_E2E=1 \
  COMMA_RELEASE_E2E_NAMESPACE="${namespace}" \
  COMMA_RELEASE_E2E_RESTART_CONTAINER="${container}" \
  COMMA_RELEASE_E2E_KUBECONFIG="${kubeconfig}" \
  COMMA_HELM_BIN="${helm_bin}" \
  GOCACHE="/tmp/comma-release-go-cache" \
  go test -C systems/ops/comma-release ./release \
    -run 'TestDisposableNamespaceRecoveryMatrix|TestHelmRecoveryE2E|TestRuntimeBundleActivationReceivesReleaseWorkerIdentity' -count=1 -timeout=15m -v
