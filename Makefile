IMAGE     ?= quay.io/jianrongzhang89/ros2-zenoh-demo
TAG       ?= latest
NAMESPACE ?= ros2-zenoh
# Native on M2; override to linux/arm64,linux/amd64 for multi-arch push
PLATFORM  ?= linux/arm64

.PHONY: all build push deploy undeploy test logs help

all: build push deploy test

## Build the container image locally (single-arch, native platform)
build:
	podman build --platform $(PLATFORM) -t $(IMAGE):$(TAG) -f Dockerfile.ros2 .

## Push the image to Quay.io (login with: podman login quay.io)
push:
	podman push $(IMAGE):$(TAG)

## Apply all Kubernetes manifests (namespace first, then everything else)
deploy:
	kubectl apply -f k8s/namespace.yaml
	kubectl apply -f k8s/

## Remove the namespace and all contained resources
undeploy:
	kubectl delete namespace $(NAMESPACE) --ignore-not-found

## Wait for all pods to be ready, then verify the listener receives messages
test:
	@echo "==> Waiting for zenoh-router..."
	kubectl rollout status deployment/zenoh-router -n $(NAMESPACE) --timeout=120s
	@echo "==> Waiting for ros2-talker..."
	kubectl rollout status deployment/ros2-talker -n $(NAMESPACE) --timeout=120s
	@echo "==> Waiting for ros2-listener..."
	kubectl rollout status deployment/ros2-listener -n $(NAMESPACE) --timeout=120s
	@echo "==> Sampling listener output..."
	@sleep 5
	@kubectl logs -n $(NAMESPACE) -l app=ros2-listener --tail=20 | grep -q "I heard" && \
		echo "PASS: listener is receiving messages from talker" || \
		(echo "FAIL: no messages received — listener logs:" && \
		 kubectl logs -n $(NAMESPACE) -l app=ros2-listener --tail=20 && exit 1)

## Stream live logs from all three pods (Ctrl-C to stop)
logs:
	@kubectl logs -n $(NAMESPACE) -l app=zenoh-router  --prefix --tail=3 &
	@kubectl logs -n $(NAMESPACE) -l app=ros2-talker   --prefix --tail=3 &
	@kubectl logs -n $(NAMESPACE) -l app=ros2-listener --prefix -f

## Show this help
help:
	@grep -E '^## ' Makefile | sed 's/## /  /'
	@echo ""
	@echo "Variables (override with make VAR=value):"
	@echo "  IMAGE=$(IMAGE)"
	@echo "  TAG=$(TAG)"
	@echo "  NAMESPACE=$(NAMESPACE)"
	@echo "  PLATFORM=$(PLATFORM)"
