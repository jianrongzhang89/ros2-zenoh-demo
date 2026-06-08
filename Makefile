IMAGE     ?= quay.io/jianrzha/ros2-zenoh-demo
VERSION   ?= 0.0.1
NAMESPACE ?= ros2-zenoh
PLATFORM  ?= linux/amd64
AUTHFILE  ?= $(HOME)/.config/containers/auth.json

.PHONY: all build push deploy undeploy test demo logs help

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

## Wait for rollout then run communication verification
test:
	kubectl rollout status deployment/zenoh-router  -n $(NAMESPACE) --timeout=120s
	kubectl rollout status deployment/ros2-talker   -n $(NAMESPACE) --timeout=120s
	kubectl rollout status deployment/ros2-listener -n $(NAMESPACE) --timeout=120s
	NAMESPACE=$(NAMESPACE) bash scripts/verify.sh

## Live-stream all three pods showing the message pipeline (Ctrl-C to stop)
demo:
	NAMESPACE=$(NAMESPACE) bash scripts/demo.sh

## Stream raw logs from all three pods (Ctrl-C to stop)
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
