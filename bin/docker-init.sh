#!/bin/bash -e

function checkEnvForEmpty() {
    property=$1
    value=$2

    if [ ! -n "$value" ]; then
        echo "[error] environment variable '$property' is empty, please define it"
        return 1
    fi
}

function execPrintOutputIfFailure() {
    command=$*

    if [ "$KUBEMACS_INIT_DEBUG" = true ]; then
        $command
        return $?
    fi
    OUTPUT="$(${command} 2>&1)"
    exitCode=$?
    if [ ! "$exitCode" -eq 0 ]; then
        echo "$OUTPUT"
    fi
    return $exitCode
}

function promptEnterOrQuit() {
    read -p "$* ([enter]|q) " prompt
    if [ "$prompt" = "q" ]; then
        return 1
    fi
    return
}

function promptEnterNoOrQuit() {
    read -p "$* ([enter]|n|q) " prompt
    if [ "$prompt" = "n" ]; then
        return 2
    fi
    if [ "$prompt" = "q" ]; then
        return 1
    fi
    return
}

# promptMultiChoice "How many nodes?" "2" "3" "4"
function promptMultiChoice() {
    local question allOptions defaultOption providedOptions options counted promptResp
    question=$1
    shift
    allOptions=$*
    defaultOption=$1
    shift
    providedOptions=$*

    options=""
    for option in $providedOptions; do
        options="$options|$option"
    done

    read -p "$question ([$defaultOption]$options) " promptResp

    counted=0
    matches=false
    for option in $allOptions; do
        counted=$((counted+=1))
        if [ $option = $promptResp ]; then
            matches=true
            break
        fi
    done

    if [ $matches = false ]; then
        counted=0
    fi

    echo $counted
}

KUBEMACS_IMAGE="${KUBEMACS_IMAGE:-}"
KUBEMACS_DOCKER_INIT_CONTAINER_NAME="${KUBEMACS_DOCKER_INIT_CONTAINER_NAME:-kubemacs-docker-init}"
KUBEMACS_INIT_DEBUG="${KUBEMACS_INIT_DEBUG:-false}"
KUBEMACS_HOST_KUBECONFIG_NAME="${KUBEMACS_HOST_KUBECONFIG_NAME:-config-kind-my-cluster}"
KUBEMACS_KIND_NAME="${KUBEMACS_KIND_NAME:-kind}"
KUBEMACS_GIT_EMAIL="${KUBEMACS_GIT_EMAIL:-}"
KUBEMACS_GIT_NAME="${KUBEMACS_GIT_NAME:-}"
KUBEMACS_TIMEZONE="${KUBEMACS_TIMEZONE:-Pacific/Auckland}"
KUBEMACS_INIT_DEFAULT_NAMESPACE="${KUBEMACS_INIT_DEFAULT_NAMESPACE:-kubemacs}"
KUBEMACS_INIT_DEFAULT_REPOS="${KUBEMACS_INIT_DEFAULT_REPOS:-}"
KUBEMACS_INIT_DEFAULT_REPOS_FOLDER="${KUBEMACS_INIT_DEFAULT_REPOS_FOLDER:-$HOME}"
KUBEMACS_INIT_DEFAULT_DIR="${KUBEMACS_INIT_DEFAULT_DIR:-/home/ii}"
KUBEMACS_INIT_ORG_FILE="${KUBEMACS_INIT_ORG_FILE:-}"
KUBEMACS_INIT_DIRECT="${KUBEMACS_INIT_DIRECT:-true}"
KUBEMACS_INIT_PREFINISH_BLOCK="${KUBEMACS_INIT_PREFINISH_BLOCK:-}"
KIND_LOCAL_REGISTRY_ENABLE=${KIND_LOCAL_REGISTRY_ENABLE:-false}
KIND_LOCAL_REGISTRY_NAME=${KIND_LOCAL_REGISTRY_NAME:-registry}
KIND_LOCAL_REGISTRY_PORT=${KIND_LOCAL_REGISTRY_PORT:-5000}
HOST_UID="${HOST_UID:-0}"

if [ $KUBEMACS_INIT_DEBUG = true ]; then
    set -x
fi

if ! ( [ -f /.dockerenv ] || [ -f /run/.containerenv ] ); then
    echo "[error] this must run in a container"
    exit 1
fi

if ! docker info -f "{.}" 2>&1 > /dev/null; then
    echo "[error] cannot talk to the Docker socket"
    exit 1
fi

if [ ! "$HOST_UID" = 0 ] && [ ! "$(id -u)" = 0 ]; then
    echo "[error] incorrect permissions to run, '--user root' is required for fixing file permissions"
    exit 1
elif [ "$HOST_UID" = 0 ]; then
    promptEnterOrQuit "It appears that HOST_UID has is set to '0' (root), this means that the new cluster's KUBECONFIG will be owned by root when it copies to your home directory. Do you wish to continue?" || exit 1
fi

if ! ( docker ps | grep "$KUBEMACS_DOCKER_INIT_CONTAINER_NAME" 2>&1 > /dev/null && docker exec -it "$KUBEMACS_DOCKER_INIT_CONTAINER_NAME" test -f /usr/local/bin/docker-init.sh 2>&1 > /dev/null ) then
   echo "[error] could not find $KUBEMACS_DOCKER_INIT_CONTAINER_NAME container, please name this container accordingly"
   exit 1
fi

if ! mountpoint -q -- /tmp/.kube; then
    echo "[error] directory '/tmp/.kube' is not a mountpoint, please mount your '\$HOME/.kube' folder."
    exit 1
fi

if ! touch "/tmp/.kube/$KUBEMACS_HOST_KUBECONFIG_NAME"; then
    echo "[error] cannot write to '/tmp/.kube', please check permissions"
fi

WILL_CREATE_CLUSTER=true
if kind get clusters | grep "$KUBEMACS_KIND_NAME" 2>&1 > /dev/null; then
    clusterDeleteOrQuit=$(promptMultiChoice "There appears to be a Kind cluster existing called '$KUBEMACS_KIND_NAME' - would you like to [d]elete it and recreate it, [a]ttach to it, [u]se the cluster, or [q]uit" "d" "a" "u" "q")
    if [ "$clusterDeleteOrQuit" = 4 ]; then
        exit 0
    elif [ "$clusterDeleteOrQuit" = 3 ]; then
        WILL_CREATE_CLUSTER=false
    elif [ "$clusterDeleteOrQuit" = 2 ]; then
        mkdir -p ~/.kube
        kind get kubeconfig > ~/.kube/config
        kubectl -n "$KUBEMACS_INIT_DEFAULT_NAMESPACE" exec -it kubemacs-0 -- attach
        exit 0
    elif [ "$clusterDeleteOrQuit" = 1 ]; then
        execPrintOutputIfFailure kind delete cluster --name "$KUBEMACS_KIND_NAME"
    else
        echo "[error] you must provide a valid option"
        exit 1
    fi
fi

if [ "$WILL_CREATE_CLUSTER" = true ]; then
cat <<EOF
| Kubemacs config                                                        |
| ---------------------------------------------------------------------- |
| Property                            | Default value    | Current value |
| ----------------------------------- | ---------------- | ------------- |
| KUBEMACS_IMAGE                      |                  | $KUBEMACS_IMAGE |
| KUBEMACS_DOCKER_INIT_CONTAINER_NAME | kubemacs-init    | $KUBEMACS_DOCKER_INIT_CONTAINER_NAME |
| KUBEMACS_INIT_DEBUG                 | false            | $KUBEMACS_INIT_DEBUG |
| KUBEMACS_HOST_KUBECONFIG_NAME       | config-kind      | $KUBEMACS_HOST_KUBECONFIG_NAME |
| KUBEMACS_KIND_NAME                  | kind             | $KUBEMACS_KIND_NAME |
| KUBEMACS_GIT_EMAIL                  |                  | $KUBEMACS_GIT_EMAIL |
| KUBEMACS_GIT_NAME                   |                  | $KUBEMACS_GIT_NAME |
| KUBEMACS_TIMEZONE                   | Pacific/Auckland | $KUBEMACS_TIMEZONE |
| DOCKER_HOST                         |                  | $DOCKER_HOST |
| KIND_LOCAL_REGISTRY_ENABLE          | false            | $KIND_LOCAL_REGISTRY_ENABLE |
| KIND_LOCAL_REGISTRY_NAME            | registry         | $KIND_LOCAL_REGISTRY_NAME |
| KIND_LOCAL_REGISTRY_PORT            | 5000             | $KIND_LOCAL_REGISTRY_PORT |
| KUBEMACS_INIT_DEFAULT_NAMESPACE     | kubemacs         | $KUBEMACS_INIT_DEFAULT_NAMESPACE |
| KUBEMACS_INIT_DEFAULT_REPOS_FOLDER  | /home/ii         | $KUBEMACS_INIT_DEFAULT_REPOS_FOLDER |
| KUBEMACS_INIT_DEFAULT_REPOS         |                  | $KUBEMACS_INIT_DEFAULT_REPOS |
| KUBEMACS_INIT_DEFAULT_DIR           | /home/ii         | $KUBEMACS_INIT_DEFAULT_DIR |
| KUBEMACS_INIT_ORG_FILE              |                  | $KUBEMACS_INIT_ORG_FILE |
| KUBEMACS_INIT_PREFINISH_BLOCK       |                  | $KUBEMACS_INIT_PREFINISH_BLOCK |
| HOST_UID                            | 0                | $HOST_UID |

EOF

    checkEnvForEmpty KUBEMACS_GIT_EMAIL "$KUBEMACS_GIT_EMAIL" || exit 1
    checkEnvForEmpty KUBEMACS_GIT_NAME  "$KUBEMACS_GIT_NAME"  || exit 1

    promptEnterOrQuit "Are you happy with using the config above?" || exit 1

    echo "[status] creating kind cluster"
    KIND_MANIFEST=/usr/share/kubemacs/kind-cluster-config.yaml
    if [ "$KIND_LOCAL_REGISTRY_ENABLE" = true ]; then
        echo "[status] setting up cluster with local Docker registry support"
        KIND_MANIFEST=/usr/share/kubemacs/kind-cluster+registry.yaml
    fi
    kind create cluster --name "$KUBEMACS_KIND_NAME" --config "$KIND_MANIFEST"
    kubectl create ns $KUBEMACS_INIT_DEFAULT_NAMESPACE
    kubectl config set-context $(kubectl config current-context) --namespace=$KUBEMACS_INIT_DEFAULT_NAMESPACE
    execPrintOutputIfFailure kubectl config set clusters.kind-"$KUBEMACS_KIND_NAME".server "https://127.0.0.1:6443"
else
    echo "[status] using existing kind cluster"
    echo "[status] copying KUBECONFIG from host"
    mkdir -p /root/.kube
    execPrintOutputIfFailure cp -f "/tmp/.kube/$KUBEMACS_HOST_KUBECONFIG_NAME" /root/.kube/config
fi

if ! kubectl cluster-info 2>&1 > /dev/null; then
    echo "[error] cannot talk to the newly created cluster - try running using '--network host'"
    if [ "$WILL_CREATE_CLUSTER" = true ]; then
        kind delete cluster --name "$KUBEMACS_KIND_NAME"
    fi
    exit 1
fi

if [ "$KIND_LOCAL_REGISTRY_ENABLE" = true ]; then
    docker pull registry:2
    running="$(docker inspect -f '{{.State.Running}}' "${KIND_LOCAL_REGISTRY_NAME}" 2>/dev/null || true)"
    if [ ! "${running}" = 'true' ]; then
        echo "[status] bringing up a local Docker registry"
        execPrintOutputIfFailure docker run \
               -d --restart=always -p "${KIND_LOCAL_REGISTRY_PORT}:5000" --name "${KIND_LOCAL_REGISTRY_NAME}" \
               registry:2
    fi
    echo "[status] ensuring nodes refer to the local Docker registry"
    # add the registry to /etc/hosts on each node
    ip_fmt='{{.NetworkSettings.IPAddress}}'
    cmd="echo $(docker inspect -f "${ip_fmt}" "${KIND_LOCAL_REGISTRY_NAME}") registry >> /etc/hosts"
    for node in $(kind get nodes --name "${KUBEMACS_KIND_NAME}"); do
        docker exec "${node}" sh -c "${cmd}"
        kubectl annotate node "${node}" \
                tilt.dev/registry=localhost:${KIND_LOCAL_REGISTRY_PORT} \
                tilt.dev/registry-from-cluster=registry:${KIND_LOCAL_REGISTRY_PORT}
    done
fi

if [ "$WILL_CREATE_CLUSTER" = true ]; then
    echo "[status] copying KUBECONFIG back to host"
    execPrintOutputIfFailure cp -f /root/.kube/config "/tmp/.kube/$KUBEMACS_HOST_KUBECONFIG_NAME"
    if [ ! -n "$HOST_UID" ]; then
        chown "$HOST_UID" "/tmp/.kube/$KUBEMACS_HOST_KUBECONFIG_NAME"
    fi
fi

if [ -z "$KUBEMACS_IMAGE" ]; then
    KUBEMACS_IMAGE="$(docker ps | grep $KUBEMACS_DOCKER_INIT_CONTAINER_NAME | awk '{$2=$2};1' | cut -d' ' -f2)"
fi

KUBEMACS_IMAGE_NAME=$(echo $KUBEMACS_IMAGE | cut -d':' -f1)
KUBEMACS_IMAGE_TAG=$(echo $KUBEMACS_IMAGE | cut -d':' -f2)

echo "[status] writing Kubemacs configs [1/2]"
echo "
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
bases:
  - ../usr/share/kubemacs/manifests/nginx-ingress/
  - ../usr/share/kubemacs/
configMapGenerator:
- name: kubemacs-configuration
  behavior: merge
  literals:
  - TZ=${KUBEMACS_TIMEZONE}
  - GIT_EMAIL=${KUBEMACS_GIT_EMAIL}
  - GIT_NAME=${KUBEMACS_GIT_NAME}
  - INIT_DEFAULT_REPOS=${KUBEMACS_INIT_DEFAULT_REPOS}
  - INIT_DEFAULT_REPOS_FOLDER=${KUBEMACS_INIT_DEFAULT_REPOS_FOLDER}
  - INIT_DEFAULT_DIR=${KUBEMACS_INIT_DEFAULT_DIR}
  - INIT_ORG_FILE=${KUBEMACS_INIT_ORG_FILE}
  - INIT_PREFINISH_BLOCK=${KUBEMACS_INIT_PREFINISH_BLOCK}
patchesJSON6902:
- target:
    group: apps
    version: v1
    kind: StatefulSet
    name: kubemacs
  path: kubemacs-patch-image.yaml
" > /root/kustomization.yaml

echo "[status] writing Kubemacs configs [2/2]"
echo "
- op: replace
  path: /spec/template/spec/containers/0/image
  value: $KUBEMACS_IMAGE
" > /root/kubemacs-patch-image.yaml

echo "[status] loading Kubemacs image into Kind from Docker"
execPrintOutputIfFailure kind load docker-image --name "$KUBEMACS_KIND_NAME" --nodes "$KUBEMACS_KIND_NAME-worker" "$KUBEMACS_IMAGE"

echo "[status] bringing up Kubemacs in Kind"
# execPrintOutputIfFailure kubectl create ns $KUBEMACS_INIT_DEFAULT_NAMESPACE
execPrintOutputIfFailure kubectl apply -k /root
kubectl delete clusterrolebinding kubemacs-crb
# TODO: Figure out how to patch a clusterrolebinding within kustomize!
# | kubectl patch clusterrolebinding kubemacs-crb --patch -
cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kubemacs-crb
subjects:
  - name: kubemacs-sa
    kind: ServiceAccount
    namespace: $KUBEMACS_INIT_DEFAULT_NAMESPACE
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
EOF
echo "[status] waiting for Kubemacs StatefulSet to have 1 ready Replica..."
while [ "$(kubectl get statefulset kubemacs -o json | jq .status.readyReplicas)" != 1 ]; do
    sleep 1s
done
echo "[status] kubemacs has 1 stateful set"

echo "[status] waiting for Kubemacs to be ready"
execPrintOutputIfFailure kubectl wait --for=condition=Ready pod/kubemacs-0

echo "[status] complete!"

echo "export KUBECONFIG=~/.kube/$KUBEMACS_HOST_KUBECONFIG_NAME
kubectl exec -it kubemacs-0 -- attach
" | /usr/local/bin/osc52.sh

echo "On your host, run:

export KUBECONFIG=~/.kube/$KUBEMACS_HOST_KUBECONFIG_NAME
kubectl exec -it kubemacs-0 -- attach

or paste in a terminal what was added to your clipboard
"

if [ "$KUBEMACS_INIT_DEBUG" = true ]; then
    bash
fi

if [ "$KUBEMACS_INIT_DIRECT" = true ]; then
    kubectl exec -it kubemacs-0 -- attach
fi
