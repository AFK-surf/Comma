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
  # COMMA_TOOL_CACHE keeps the verified archive between runs on one CI node.
  cached="${COMMA_TOOL_CACHE:+${COMMA_TOOL_CACHE}/helm-v4.2.2-${os}-${arch}.tar.gz}"
  if [[ -n "${cached}" && -f "${cached}" ]]; then
    cp "${cached}" "${helm_archive}"
  else
    curl --fail --silent --show-error --location \
      "https://get.helm.sh/helm-v4.2.2-${os}-${arch}.tar.gz" --output "${helm_archive}"
  fi
  if [[ "${os}" == darwin ]]; then
    echo "${helm_sha}  ${helm_archive}" | shasum -a 256 --check
  else
    echo "${helm_sha}  ${helm_archive}" | sha256sum --check --strict
  fi
  if [[ -n "${cached}" && ! -f "${cached}" ]]; then
    mkdir -p "${COMMA_TOOL_CACHE}"
    cp "${helm_archive}" "${cached}.$$" && mv "${cached}.$$" "${cached}"
  fi
  tar -xzf "${helm_archive}" -C "${workspace}"
  helm_bin="${workspace}/${os}-${arch}/helm"
fi

cleanup() {
  local status=$?
  # A failed run says what the local Kubernetes did: whether k3s stopped,
  # restarted or refused its API, which the tests' own errors cannot tell.
  if [[ "${status}" != 0 ]]; then
    echo "::group::k3s container after the failure"
    docker inspect --format 'state={{.State.Status}} restarts={{.RestartCount}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}} started={{.State.StartedAt}} finished={{.State.FinishedAt}}' "${container}" 2>&1 || true
    docker logs --timestamps --tail 300 "${container}" 2>&1 || true
    echo "::endgroup::"
  fi
  if [[ -f "${kubeconfig}" ]]; then
    KUBECONFIG="${kubeconfig}" kubectl delete namespace "${namespace}" --ignore-not-found=true --wait=false >/dev/null 2>&1 || true
  fi
  docker rm -f "${container}" >/dev/null 2>&1 || true
  rm -rf "${workspace}"
}
trap cleanup EXIT

# k3s's embedded cloud controller can start before the API server has granted
# it the role that reads extension-apiserver-authentication; it then exits and
# takes the whole server down a few seconds after /readyz passed (main
# ee78b012e). This single-node cluster has no cloud to control.
docker create --privileged --name "${container}" \
  --publish 127.0.0.1::6443 \
  rancher/k3s:v1.35.5-k3s1 server \
  --disable=traefik --disable=servicelb --disable=metrics-server \
  --disable-cloud-controller --tls-san=127.0.0.1 >/dev/null
# COMMA_K3S_IMAGES names images already in the Docker daemon that k3s imports
# at start instead of pulling them: its system images and the tests' own.
if [[ -n "${COMMA_K3S_IMAGES:-}" ]]; then
  mkdir -p "${workspace}/agent/images"
  # shellcheck disable=SC2086
  docker save -o "${workspace}/agent/images/preloaded.tar" ${COMMA_K3S_IMAGES}
  docker cp "${workspace}/agent" "${container}:/var/lib/rancher/k3s/" >/dev/null
fi
docker start "${container}" >/dev/null

# On cgroup v2, k3s first moves the container's processes out of its root
# cgroup so it can enable the controllers there, and logs "Starting k3s" after.
# A `docker exec` in that moment lands in the root cgroup: enabling the
# controllers fails with "device or resource busy" and the kubelet then exits
# k3s ("missing controllers"). `docker logs` runs nothing in the container.
for _ in $(seq 1 90); do
  if docker logs "${container}" 2>&1 | grep "Starting k3s" >/dev/null; then
    break
  fi
  sleep 1
done

for _ in $(seq 1 90); do
  if docker exec "${container}" kubectl get --raw=/readyz >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
docker exec "${container}" kubectl get --raw=/readyz >/dev/null

# Runners without kubectl use the k3s binary of this container; it serves
# kubectl when called by that name.
if ! command -v kubectl >/dev/null 2>&1; then
  mkdir -p "${workspace}/bin"
  docker cp -L "${container}:/bin/kubectl" "${workspace}/bin/kubectl" >/dev/null
  export PATH="${workspace}/bin:${PATH}"
fi

docker cp "${container}:/etc/rancher/k3s/k3s.yaml" "${kubeconfig}" >/dev/null
endpoint="$(docker port "${container}" 6443/tcp)"
sed -i.bak "s#127.0.0.1:6443#${endpoint}#" "${kubeconfig}"

KUBECONFIG="${kubeconfig}" kubectl create namespace "${namespace}" >/dev/null
# The chart tests parse the rendered manifests with PyYAML.
python=(python3)
if command -v uv >/dev/null 2>&1; then
  python=(uv run --no-project --with pyyaml==6.0.3 python3)
fi
# COMMA_RELEASE_E2E_PART splits the run across CI jobs: `matrix` runs the
# disposable-namespace recovery matrix, `rest` everything else; unset, all.
part="${COMMA_RELEASE_E2E_PART:-all}"
case "${part}" in
  all) tests='TestDisposableNamespaceRecoveryMatrix|TestHelmRecoveryE2E|TestHelmRepairE2E|TestRuntimeBundleActivationReceivesReleaseWorkerIdentity' ;;
  matrix) tests='TestDisposableNamespaceRecoveryMatrix' ;;
  rest) tests='TestHelmRecoveryE2E|TestHelmRepairE2E|TestRuntimeBundleActivationReceivesReleaseWorkerIdentity' ;;
  *) echo "unknown COMMA_RELEASE_E2E_PART: ${part}" >&2; exit 2 ;;
esac
if [[ "${part}" != matrix ]]; then
  KUBECONFIG="${kubeconfig}" "${python[@]}" k8s/comma/chart/test_proxy_lifecycle.py \
    --context default --helm "${helm_bin}"
  KUBECONFIG="${kubeconfig}" "${python[@]}" k8s/comma/chart/test_scheduling.py \
    --context default --helm "${helm_bin}"
fi
KUBECONFIG="${kubeconfig}" \
  COMMA_RELEASE_KUBERNETES_E2E=1 \
  COMMA_RELEASE_E2E_NAMESPACE="${namespace}" \
  COMMA_RELEASE_E2E_RESTART_CONTAINER="${container}" \
  COMMA_RELEASE_E2E_KUBECONFIG="${kubeconfig}" \
  COMMA_HELM_BIN="${helm_bin}" \
  GOCACHE="/tmp/comma-release-go-cache" \
  go test -C systems/ops/comma-release ./release \
    -run "^(${tests})\$" -count=1 -timeout=15m -v
