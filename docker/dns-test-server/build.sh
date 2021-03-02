#!/bin/bash

REGISTRY="quay.io"
BUILD_IMAGE="travelping/ergw-dns-test-server"

docker buildx build \
       -f Dockerfile \
       --platform=linux/arm64,linux/amd64 -t ${REGISTRY}/${BUILD_IMAGE}:latest \
       --push --no-cache .
