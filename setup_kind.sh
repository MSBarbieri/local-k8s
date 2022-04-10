#!/bin/bash

set -e

REQUISITES=("kubectl" "kind" "docker" "helm" "istioctl")
for item in "${REQUISITES[@]}"; do
  if [[ -z $(which "${item}") ]]; then
    echo "${item} cannot be found on your system, please install ${item}"
    exit 1
  fi
done
function print {
  echo -e " "
  echo -e " "
  echo -e "$1 ..."
  echo -e "--------------------------------"
}

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
  -h | --help)
    printHelp
    exit 0
    ;;
  -n | --cluster-name)
    CLUSTERNAME="$2"
    shift
    shift
    ;;
  *) # unknown option
    echo "parameter $1 is not supported"
    exit 1
    ;;
  esac
done

function create_custer {
  has_clusters=$(kind get clusters)
  if [[ $has_clusters == *"$CLUSTERNAME"* ]]; then
    echo -e "cluster already exists"
  else
    kind create cluster --name="${CLUSTERNAME}" --config=./kind/kind_config.yaml
  fi
}

function setup_baremetal {
  print "enabling bare metal cluster"
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
  while :; do
    IP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${CLUSTERNAME}"-control-plane)
    if [[ -n "${IP}" ]]; then
      # Change the kubeconfig file not to use the loopback IP
      kubectl config set clusters.kind-"${CLUSTERNAME}".server https://"${IP}":6443
      break
    fi
    echo 'Waiting for public IP address to be available...'
    sleep 3
  done
}

function setup_istio {
  print "installing istio"
  istioctl install -f ./istio/install_istio.yaml -y
  kubectl label namespace default istio-injection=enabled
}

function setup_elk {
  print "installing elk stack"
  has_repo=$(helm repo list | grep elastic)
  if [[ ! -z $has_repo ]]; then
    echo -e "elastic repo already installed"
  else
    helm repo add elastic https://helm.elastic.co
    helm repo update
  fi

  kubectl create namespace elk
  helm install elasticsearch elastic/elasticsearch --namespace elk -f ./elk/elasticsearch.yaml
  helm install logstash elastic/logstash --namespace elk -f ./elk/logstash.yaml
  helm install kibana elastic/kibana --namespace elk -f ./elk/kibana.yaml
  helm install metricbeat elastic/metricbeat --namespace elk -f ./elk/metricbeat.yaml
}

function create_networks {
  print "creating default networks"
  kubectl apply -f ./istio/general_network.yaml
  kubectl apply -f ./istio/elk_network.yaml
}

create_custer
setup_baremetal
setup_istio
setup_elk
create_networks