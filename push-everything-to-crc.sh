#!/usr/bin/env bash

echo "### Deploy all Operator resources to OpenShift"
kustomize build config/default | oc apply -f -

echo "### Build the Operator container image locally"
podman build . \
  -t default-route-openshift-image-registry.apps-crc.testing/ansible-nginx-operator-system/controller:latest

echo "### Login to OpenShift Registry API"
podman login \
  --tls-verify=false \
  -u kubeadmin -p $(oc whoami -t) \
  default-route-openshift-image-registry.apps-crc.testing

echo "### Push the Operator container image to the OpenShift Registry"
podman push \
  --tls-verify=false \
  default-route-openshift-image-registry.apps-crc.testing/ansible-nginx-operator-system/controller:latest