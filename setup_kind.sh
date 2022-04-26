#!/bin/bash

set -e

REQUISITES=("kubectl" "kind" "docker" "helm" "istioctl" "kustomize")
for item in "${REQUISITES[@]}"; do
  if [[ -z $(which "${item}") ]]; then
    echo "${item} cannot be found on your system, please install ${item}"
    exit 1
  fi
done


#Function to print the usage message
function printHelp() {
  echo "Usage: "
  echo "    $0 --cluster-name challange --ip-octet 255"
  echo ""
  echo "Where:"
  echo "    -n|--cluster-name  - name of the k8s cluster to be created"
  echo "    -s|--ip-octet      - the 3rd octet for public ip addresses, 255 if not given, valid range: 0-255"
  echo "    -h|--help          - print the usage of this script"
}

#Setup default values
CLUSTERNAME="challange"
K8SRELEASE=""
IPSPACE=255

#Handling parameters
while [[ $# -gt 0 ]]; do
  optkey="$1"
  case $optkey in
    -h|--help)
      printHelp; exit 0;;
    -n|--cluster-name)
      CLUSTERNAME="$2";shift;shift;;
    *) # unknown option
      echo "parameter $1 is not supported"; exit 1;;
  esac
done

has_clusters=$(kind get clusters)
if [[ $has_clusters == *"$CLUSTERNAME"* ]]; then
    echo -e "cluster already exists"
else
    kind create cluster --name="${CLUSTERNAME}" --config=kind/kind_config.yaml
fi

kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.12.1/manifests/namespace.yaml
kubectl create secret generic -n metallb-system memberlist --from-literal=secretkey="$RANDOM-$RANDOM-$RANDOM-$RANDOM-$RANDOM"
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.12.1/manifests/metallb.yaml

# The following makes sure that the kube configuration for the cluster is not
# using the loopback ip as part of the api server endpoint. Without this,
# multiple clusters would not be able to interact with each other.
PREFIX=$(docker network inspect -f '{{range .IPAM.Config }}{{ .Gateway }}{{end}}' kind | cut -d '.' -f1,2)

# Now configure the loadbalancer public IP range
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  namespace: metallb-system
  name: config
data:
  config: |
    address-pools:
    - name: default
      protocol: layer2
      addresses:
      - $PREFIX.$IPSPACE.200-$PREFIX.$IPSPACE.240
EOF

# Wait for the public IP address to become available.
while : ; do
  IP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${CLUSTERNAME}"-control-plane)
  if [[ -n "${IP}" ]]; then
    # Change the kubeconfig file not to use the loopback IP
    kubectl config set clusters.kind-"${CLUSTERNAME}".server https://"${IP}":6443
    break
  fi
  echo 'Waiting for public IP address to be available...'
  sleep 3
done


echo -e " "
echo -e " "
echo -e " "
echo -e "installing Istio..."
istioctl install -f ./istio/install_istio.yaml -y
kubectl label namespace default istio-injection=enabled
kubectl apply -k ./istio

echo -e " "
echo -e " "
echo -e " "
echo -e "installing argo..."
kubectl create namespace argocd
kubectl apply -k argo

echo -e " "
echo -e "waiting argocd to be ready..."
kubectl wait deployment -n argocd argocd-server --for condition=Available=True --timeout=600s
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d > argocd_password
echo -e "argo password generated successfully, user is: admin, password is in argocd_password file"
echo -e "enter in argocd use the link: http://argocd.localhost"
kubectl apply -k argo/applications