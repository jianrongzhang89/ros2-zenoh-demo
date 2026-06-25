IMAGE          ?= quay.io/jianrzha/ros2-zenoh-demo
VERSION        ?= 0.0.1
NAMESPACE      ?= ros2-zenoh
BRIDGE_NS      ?= ros2-zenoh-bridge
FEDERATION_NS  ?= ros2-zenoh-federation
PLATFORM       ?= linux/amd64,linux/arm64
AUTHFILE       ?= $(HOME)/.config/containers/auth.json

.PHONY: all build push deploy undeploy test demo logs \
        deploy-bridge undeploy-bridge test-bridge demo-bridge logs-bridge \
        mirror-bridge \
        test-filtering test-filtering-scenario \
        test-federation test-federation-scenario \
        deploy-federation undeploy-federation test-federation-ocp test-federation-ocp-scenario \
        help

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

## Apply zenoh-bridge-ros2dds manifests to k8s/bridge/, substituting IMAGE:VERSION
deploy-bridge:
	kubectl apply -f k8s/bridge/namespace.yaml
	@for f in k8s/bridge/configmap-*.yaml k8s/bridge/service-*.yaml k8s/bridge/deployment-*.yaml; do \
		sed 's|$(IMAGE):latest|$(IMAGE):$(VERSION)|g' $$f | kubectl apply -f -; \
	done

## Remove the bridge namespace and all contained resources
undeploy-bridge:
	kubectl delete namespace $(BRIDGE_NS) --ignore-not-found

## Wait for rollout then run bridge communication verification
test-bridge:
	kubectl rollout status deployment/zenoh-bridge-router -n $(BRIDGE_NS) --timeout=120s
	kubectl rollout status deployment/ros2-dds-talker     -n $(BRIDGE_NS) --timeout=120s
	kubectl rollout status deployment/ros2-dds-listener   -n $(BRIDGE_NS) --timeout=120s
	NAMESPACE=$(BRIDGE_NS) bash scripts/verify-bridge.sh

## Live-stream the bridge message pipeline (Ctrl-C to stop)
demo-bridge:
	NAMESPACE=$(BRIDGE_NS) bash scripts/demo-bridge.sh

## Stream raw logs from all bridge pods (Ctrl-C to stop)
logs-bridge:
	@kubectl logs -n $(BRIDGE_NS) -l app=zenoh-bridge-router             --prefix --tail=3 &
	@kubectl logs -n $(BRIDGE_NS) -l app=ros2-dds-talker   -c ros2-talker  --prefix --tail=3 &
	@kubectl logs -n $(BRIDGE_NS) -l app=ros2-dds-talker   -c zenoh-bridge --prefix --tail=3 &
	@kubectl logs -n $(BRIDGE_NS) -l app=ros2-dds-listener -c ros2-listener --prefix --tail=3 &
	@kubectl logs -n $(BRIDGE_NS) -l app=ros2-dds-listener -c zenoh-bridge --prefix -f

## Run all 8 bridge filtering scenarios locally (requires: podman machine running)
test-filtering:
	bash scripts/test-bridge-filtering.sh

## Run a single filtering scenario: make test-filtering-scenario N=2  (N=1..8)
test-filtering-scenario:
	SCENARIO=$(N) bash scripts/test-bridge-filtering.sh

## Run all router federation scenarios locally (requires: podman machine running)
test-federation:
	bash scripts/test-federation.sh

## Run a single federation scenario: make test-federation-scenario N=F1  (N=F1|F2|F3)
test-federation-scenario:
	SCENARIO=$(N) bash scripts/test-federation.sh

## Apply federation manifests to k8s/federation/ (namespace + configmap + routers + pods)
deploy-federation:
	kubectl apply -f k8s/federation/namespace.yaml
	@for f in k8s/federation/configmap-*.yaml k8s/federation/service-*.yaml k8s/federation/deployment-*.yaml; do \
		kubectl apply -f $$f; \
	done

## Remove the federation namespace and all contained resources
undeploy-federation:
	kubectl delete namespace $(FEDERATION_NS) --ignore-not-found

## Run all federation scenarios against a live OpenShift/Kubernetes cluster
test-federation-ocp:
	NAMESPACE=$(FEDERATION_NS) bash scripts/test-federation-ocp.sh

## Run a single OCP federation scenario: make test-federation-ocp-scenario N=F1  (N=F1|F2|F3)
test-federation-ocp-scenario:
	NAMESPACE=$(FEDERATION_NS) SCENARIO=$(N) bash scripts/test-federation-ocp.sh

## Mirror upstream Zenoh images to Quay.io (requires QUAY_USERNAME / QUAY_PASSWORD env vars)
## eclipse/zenoh:latest is also used by the local filtering tests (Scenario 8 router ACL).
mirror-bridge:
	skopeo copy --multi-arch all \
		--dest-creds "$(QUAY_USERNAME):$(QUAY_PASSWORD)" \
		docker://docker.io/eclipse/zenoh-bridge-ros2dds:latest \
		docker://quay.io/jianrzha/zenoh-bridge-ros2dds:latest
	skopeo copy --multi-arch all \
		--dest-creds "$(QUAY_USERNAME):$(QUAY_PASSWORD)" \
		docker://docker.io/eclipse/zenoh:latest \
		docker://quay.io/jianrzha/zenoh-router:latest

## Show this help
help:
	@grep -E '^## ' Makefile | sed 's/## /  /'
	@echo ""
	@echo "Variables (override with make VAR=value):"
	@echo "  IMAGE=$(IMAGE)"
	@echo "  VERSION=$(VERSION)"
	@echo "  NAMESPACE=$(NAMESPACE)"
	@echo "  BRIDGE_NS=$(BRIDGE_NS)"
	@echo "  PLATFORM=$(PLATFORM)"
