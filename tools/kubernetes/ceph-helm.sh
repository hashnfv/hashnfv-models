#!/bin/bash
# Copyright 2017 AT&T Intellectual Property, Inc
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
#. What this is: script to setup a Ceph-based SDS (Software Defined Storage)
#. service for a kubernetes cluster, using Helm as deployment tool.
#. Prerequisites:
#. - Ubuntu xenial server for master and agent nodes
#. - key-based auth setup for ssh/scp between master and agent nodes
#. - 192.168.0.0/16 should not be used on your server network interface subnets
#. Usage:
#  Intended to be called from k8s-cluster.sh in this folder. To run directly:
#. $ bash ceph-helm.sh "<nodes>" <cluster-net> <public-net> [ceph_dev]
#.     nodes: space-separated list of ceph node IPs
#.     cluster-net: CIDR of ceph cluster network e.g. 10.0.0.1/24
#.     public-net: CIDR of public network
#.     ceph_dev: disk to use for ceph. ***MUST NOT BE USED FOR ANY OTHER PURPOSE***
#.               if not provided, ceph data will be stored on osd nodes in /ceph
#.
#. Status: work in progress, incomplete
#

function setup_ceph() {
  nodes=$1
  private_net=$2
  public_net=$3
  dev=$4
  # per https://github.com/att/netarbiter/tree/master/sds/ceph-docker/examples/helm
  echo "${FUNCNAME[0]}: Clone netarbiter"
  git clone https://github.com/att/netarbiter.git
  cd netarbiter/sds/ceph-docker/examples/helm

  echo "${FUNCNAME[0]}: Prepare a ceph namespace in your K8s cluster"
  ./prep-ceph-ns.sh

  echo "${FUNCNAME[0]}: Run ceph-mon, ceph-mgr, ceph-mon-check, and rbd-provisioner"
  # Pre-req per https://github.com/att/netarbiter/tree/master/sds/ceph-docker/examples/helm#notes
  kubedns=$(kubectl get service -o json --namespace kube-system kube-dns | \
    jq -r '.spec.clusterIP')

  cat <<EOF | sudo tee /etc/resolv.conf
nameserver $kubedns
search ceph.svc.cluster.local svc.cluster.local cluster.local
options ndots:5
EOF

  ./helm-install-ceph.sh cephtest $private_net $public_net

  echo "${FUNCNAME[0]}: Check the pod status of ceph-mon, ceph-mgr, ceph-mon-check, and rbd-provisioner"
  services="rbd-provisioner ceph-mon-0 ceph-mgr ceph-mon-check"
  for service in $services; do
    pod=$(kubectl get pods --namespace ceph | awk "/$service/{print \$1}")
    status=$(kubectl get pods --namespace ceph $pod -o json | jq -r '.status.phase')
    while [[ "x$status" != "xRunning" ]]; do
      echo "${FUNCNAME[0]}: $pod status is \"$status\". Waiting 10 seconds for it to be 'Running'"
      sleep 10
      status=$(kubectl get pods --namespace ceph $pod -o json | jq -r '.status.phase')
    done
  done
  kubectl get pods --namespace ceph

  echo "${FUNCNAME[0]}: Check ceph health status"
  status=$(kubectl -n ceph exec -it ceph-mon-0 -- ceph -s | awk "/health:/{print \$2}")
  while [[ "x$status" != "xHEALTH_OK" ]]; do
    echo "${FUNCNAME[0]}: ceph status is \"$status\". Waiting 10 seconds for it to be 'HEALTH_OK'"
    kubectl -n ceph exec -it ceph-mon-0 -- ceph -s
    sleep 10
    status=$(kubectl -n ceph exec -it ceph-mon-0 -- ceph -s | awk "/health:/{print \$2}")
  done
  echo "${FUNCNAME[0]}: ceph status is 'HEALTH_OK'"
  kubectl -n ceph exec -it ceph-mon-0 -- ceph -s

  for node in $nodes; do
    echo "${FUNCNAME[0]}: setup resolv.conf for $node"
    ssh -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
      ubuntu@$node <<EOG
cat <<EOF | sudo tee /etc/resolv.conf
nameserver $kubedns
search ceph.svc.cluster.local svc.cluster.local cluster.local
options ndots:5
EOF
EOG
    echo "${FUNCNAME[0]}: Zap disk $dev at $node"
    ssh -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
      ubuntu@$node sudo ceph-disk zap /dev/$dev
    echo "${FUNCNAME[0]}: Run ceph-osd at $node"
    name=$(ssh -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
      ubuntu@$node hostname)
    ./helm-install-ceph-osd.sh $name /dev/$dev
  done

  for node in $nodes; do
    name=$(ssh -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
      ubuntu@$node hostname)
    pod=$(kubectl get pods --namespace ceph | awk "/$name/{print \$1}")
    echo "${FUNCNAME[0]}: verify ceph-osd is Running at node $name"
    status=$(kubectl get pods --namespace ceph $pod | awk "/$pod/ {print \$3}")
    while [[ "x$status" != "xRunning" ]]; do
      echo "${FUNCNAME[0]}: $pod status is $status. Waiting 10 seconds for it to be Running."
      sleep 10
      status=$(kubectl get pods --namespace ceph $pod | awk "/$pod/ {print \$3}")
      kubectl get pods --namespace ceph
    done
  done

  echo "${FUNCNAME[0]}: WORKAROUND take ownership of .kube"
  # TODO: find out why this is needed
  sudo chown -R ubuntu:ubuntu ~/.kube/*

  echo "${FUNCNAME[0]}: Activate Ceph for namespace 'default'"
  ./activate-namespace.sh default

  echo "${FUNCNAME[0]}: Relax access control rules"
  kubectl replace -f relax-rbac-k8s1.7.yaml

  echo "${FUNCNAME[0]}: Setup complete, running smoke tests"
  echo "${FUNCNAME[0]}: Create a pool from a ceph-mon pod (e.g., ceph-mon-0)"

  kubectl -n ceph exec -it ceph-mon-0 -- ceph osd pool create rbd 100 100

  echo "${FUNCNAME[0]}: Create a pvc and check if the pvc status is Bound"

  kubectl create -f tests/ceph/pvc.yaml
  status=$(kubectl get pvc ceph-test -o json | jq -r '.status.phase')
  while [[ "$status" != "Bound" ]]; do
    echo "${FUNCNAME[0]}: pvc status is $status, waiting 10 seconds for it to be Bound"
    sleep 10
    status=$(kubectl get pvc ceph-test -o json | jq -r '.status.phase')
  done
  echo "${FUNCNAME[0]}: pvc ceph-test successfully bound to $(kubectl get pvc -o jsonpath='{.spec.volumeName}' ceph-test)"
  kubectl describe pvc

  echo "${FUNCNAME[0]}: Attach the pvc to a job and check if the job is successful (i.e., 1)"
  kubectl create -f tests/ceph/job.yaml
  status=$(kubectl get jobs ceph-secret-generator -n ceph -o json | jq -r '.status.succeeded')
  if [[ "$status" != "1" ]]; then
    echo "${FUNCNAME[0]}: pvc attachment was not successful:"
    kubectl get jobs ceph-secret-generator -n ceph -o json
    exit 1
  fi

  echo "${FUNCNAME[0]}: Verify that the test job was successful"
  pod=$(kubectl get pods --namespace default | awk "/ceph-test/{print \$1}")
  active=$(kubectl get jobs --namespace default -o json ceph-test-job | jq -r '.status.active')
  while [[ $active > 0 ]]; do
    echo "${FUNCNAME[0]}: test job is still running, waiting 10 seconds for it to complete"
    kubectl describe pods --namespace default $pod | awk '/Events:/{y=1;next}y'
    sleep 10
    active=$(kubectl get jobs --namespace default -o json ceph-test-job | jq -r '.status.active')
  done
  echo "${FUNCNAME[0]}: test job succeeded"

  kubectl delete jobs ceph-secret-generator -n ceph
  kubectl delete pvc ceph-test
  echo "${FUNCNAME[0]}: Ceph setup complete!"
}

if [[ "$1" != "" ]]; then
  setup_ceph "$1" $2 $3 $4
else
  grep '#. ' $0
fi
