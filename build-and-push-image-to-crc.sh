#!/usr/bin/env bash

# Build the pod under its target Dockerref
podman build . \
  -t default-route-openshift-image-registry.apps-crc.testing/ansible-nginx-operator-system/controller:latest

# Login to OpenShift Registry
podman login \
  --tls-verify=false \
  -u kubeadmin -p $(oc whoami -t) \
  default-route-openshift-image-registry.apps-crc.testing

# Push to OpenShift Registry
podman push \
  --tls-verify=false \
  default-route-openshift-image-registry.apps-crc.testing/ansible-nginx-operator-system/controller:latest