IMAGE     ?= quay.io/jianrzha/ros2-zenoh-demo
VERSION   ?= 0.0.1
NAMESPACE ?= ros2-zenoh
PLATFORM  ?= linux/amd64
AUTHFILE  ?= $(HOME)/.config/containers/auth.json

.PHONY: all build push deploy undeploy test logs help

all: build push deploy test

## Build the container image
build:
	podman build --platform $(PLATFORM) -t $(IMAGE):$(VERSION) -f Dockerfile.ros2 .

## Push the image to Quay.io (login with: podman login quay.io --authfile $(AUTHFILE))
push:
	podman push --authfile $(AUTHFILE) $(IMAGE):$(VERSION)

## Apply all Kubernetes manifests, substituting the current IMAGE:VERSION
deploy:
	kubectl apply -f k8s/namespace.yaml
	@for f in k8s/configmap-*.yaml k8s/service-*.yaml k8s/deployment-*.yaml; do \
		sed 's|$(IMAGE):latest|$(IMAGE):$(VERSION)|g' $$f | kubectl apply -f -; \
	done

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
	@echo "  VERSION=$(VERSION)"
	@echo "  NAMESPACE=$(NAMESPACE)"
	@echo "  PLATFORM=$(PLATFORM)"
