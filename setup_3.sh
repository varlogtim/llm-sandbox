#!/bin/bash
if [[ -z "${MINIO_KEY}" ]]; then
  echo "MINIO_KEY is undefined"
  exit 1
elif [[ -z "${MINIO_SECRET}" ]]; then
  echo "MINIO_SECRET is undefined"
  exit 1
fi
if [[ ! -d "$PWD/aioli" ]]; then
	echo "Could not find Aioli directory here ${PWD}/aioli. Have you downloaded and extracted the helm chart?" 1>&2
    exit 1
fi

MLIS_NAMESPACE="mlis"

set -e
set -x

sudo microk8s kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.15.1/cert-manager.yaml

export PATH="$PATH:/home/ubuntu/istio-1.21.5/bin"
istioctl install -y

sudo microk8s kubectl apply -f https://github.com/knative/serving/releases/download/knative-v1.13.1/serving-crds.yaml

sudo microk8s kubectl apply -f https://github.com/knative/serving/releases/download/knative-v1.13.1/serving-core.yaml
sudo microk8s kubectl apply -f https://github.com/knative/net-istio/releases/download/knative-v1.13.1/net-istio.yaml


sudo microk8s kubectl run -n minio-operator mc --restart=Never --image=minio/mc --command -- /bin/sh -c 'while true; do sleep 5s; done'
sleep 5
sudo microk8s kubectl exec -n minio-operator --stdin --tty mc -- mc alias set microk8s http://minio:80 $MINIO_KEY $MINIO_SECRET
sudo microk8s kubectl exec -n minio-operator --stdin --tty mc -- mc mb -p microk8s/pach
sudo microk8s kubectl exec -n minio-operator --stdin --tty mc -- mc mb -p microk8s/models
sudo microk8s kubectl delete pod -n minio-operator mc

export PUBLIC_DNS=$(curl -s http://icanhazip.com).nip.io

cat > mldm-values.yaml << EOF
deployTarget: MINIO
proxy:
  host: $PUBLIC_DNS
  enabled: true
  service:
    type: NodePort
pachd:
  enterpriseLicenseKey: $MLDM_LICENSE_KEY
  activateAuth: false
  storage:
    backend: AMAZON
    gocdkEnabled: true
    storageURL: "s3://pach?endpoint=minio.minio-operator.svc.cluster.local:80&disableSSL=true&region=us-east-1"
    amazon:
      id: "$MINIO_KEY"
      secret: "$MINIO_SECRET"
EOF

sudo microk8s helm3 upgrade -i mldm pach/pachyderm -f mldm-values.yaml


sudo microk8s kubectl apply -f https://github.com/kserve/kserve/releases/download/v0.13.0/kserve.yaml


cat << 'EOF' > mlis-values.yaml
defaultPassword: HPE2024Password
defaultImages:
  openllm: aioli-runtimes@sha256:4fa0b6a98defa50ec3126b23ecbe6f3a0c6587351691c29a4ca0a41adbde4a8f
global:
  imagePullSecrets:
  - name: my-registry-secret
proxy:
  type: NodePort
EOF


# Create mlis Name space
set +e +x
OUT=$(sudo microk8s kubectl create ns "${MLIS_NAMESPACE}" 2>&1)
RETCODE=$?
if [[ $RETCODE -ne 0 ]]; then
	if [[ "${OUT}" == *"AlreadyExists"* ]]; then
		echo "Namespace '${MLIS_NAMESPACE}' already exists. Continuing"
	else
		echo "Create namespace failed: ${OUT}" 1>&2
	fi
fi
set -e -x


# (Re)Create secret
set +e +x
SECRET_NAME="my-registry-secret"
sudo microk8s kubectl describe secret -n "${MLIS_NAMESPACE}" "${SECRET_NAME}" > /dev/null
RETCODE=$?
if [[ $RETCODE == 0 ]]; then
	echo "secret \"${SECRET_NAME}\" already exists, removing."
	sudo microk8s kubectl delete secret -n "${MLIS_NAMESPACE}" "${SECRET_NAME}" ||
		(echo "Failed to delete secret" && exit 1)
fi
sudo microk8s kubectl create secret docker-registry -n "${MLIS_NAMESPACE}" "${SECRET_NAME}" \
	--docker-username="${DOCKER_USER}" \
	--docker-password="${DOCKER_TOKEN}" ||
    (echo "Failed to create secret!" 1>&2 && exit 1)
set -e -x


cat > config-domain.yaml << EOF
apiVersion: v1
data:
  $PUBLIC_DNS: ""
kind: ConfigMap
metadata:
  labels:
    app.kubernetes.io/component: controller
    app.kubernetes.io/name: knative-serving
    app.kubernetes.io/version: 1.14.1
  name: config-domain
  namespace: knative-serving
EOF

# install mlis
sudo microk8s helm3 upgrade -i mlis aioli/ -n "${MLIS_NAMESPACE}" -f mlis-values.yaml

# set the external domain for knative/mlis
sudo microk8s kubectl apply -f config-domain.yaml

# install open-webui
sudo microk8s helm3 upgrade -i open-webui open-webui/open-webui -n open-webui --create-namespace --set ollama.enabled=false --set pipelines.enabled=false --set service.type=NodePort

# patch for knative serving garbage collection for MLIS

sudo microk8s kubectl patch cm  -n knative-serving config-gc  --type=strategic \
      -p '{"data":{"min-non-active-revisions":"0", "max-non-active-revisions": "0", "retain-since-create-time": "disabled","retain-since-last-active-time": "disabled"}}'

set +x
echo "All software is installed. If you wish to stop here, you can."
echo "If you want to install the rag pipelines and starter models, run the next script setup_4.sh"
echo "Before that you'll need to export the HF_TOKEN environment variable with your Hugging Face API token."
echo "check the notes in setup_4.sh, you may need to adjust the configuration for different GPU types"
echo "you can now run setup_4.sh"
