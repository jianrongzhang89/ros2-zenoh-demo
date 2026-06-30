QUAY_ORG       ?= ecosystem-appeng
DEMO_ORG       ?= jianrzha
IMAGE          ?= quay.io/$(DEMO_ORG)/ros2-zenoh-demo
ROUTER_IMAGE   ?= quay.io/$(QUAY_ORG)/zenoh-router
BRIDGE_IMAGE   ?= quay.io/$(QUAY_ORG)/zenoh-bridge-ros2dds
VERSION        ?= 0.0.1
ECLIPSE_TAG    ?= 1.9.0
NAMESPACE      ?= ros2-zenoh
BRIDGE_NS      ?= ros2-zenoh-bridge
FEDERATION_NS  ?= ros2-zenoh-federation
PLATFORM       ?= linux/amd64,linux/arm64
AUTHFILE       ?= $(HOME)/.config/containers/auth.json

.PHONY: all build push deploy undeploy test demo logs \
        build-router build-bridge build-ubi push-router push-bridge push-ubi \
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

## Apply zenoh-bridge-ros2dds manifests to k8s/bridge/, substituting image tags
deploy-bridge:
	kubectl apply -f k8s/bridge/namespace.yaml
	@for f in k8s/bridge/configmap-*.yaml k8s/bridge/service-*.yaml k8s/bridge/deployment-*.yaml; do \
		sed -e 's|$(IMAGE):latest|$(IMAGE):$(VERSION)|g' \
		    -e 's|$(ROUTER_IMAGE):latest|$(ROUTER_IMAGE):$(ECLIPSE_TAG)|g' \
		    -e 's|$(BRIDGE_IMAGE):latest|$(BRIDGE_IMAGE):$(ECLIPSE_TAG)|g' \
		    $$f | kubectl apply -f -; \
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
		sed -e 's|$(ROUTER_IMAGE):latest|$(ROUTER_IMAGE):$(ECLIPSE_TAG)|g' \
		    -e 's|$(BRIDGE_IMAGE):latest|$(BRIDGE_IMAGE):$(ECLIPSE_TAG)|g' \
		    $$f | kubectl apply -f -; \
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

## Build UBI-based zenoh router image (multi-stage: binary extracted from eclipse/zenoh)
build-router:
	podman manifest rm $(ROUTER_IMAGE):$(VERSION) 2>/dev/null || true
	podman rmi $(ROUTER_IMAGE):$(VERSION) 2>/dev/null || true
	podman build --platform $(PLATFORM) \
		--build-arg ECLIPSE_TAG=$(ECLIPSE_TAG) \
		--manifest $(ROUTER_IMAGE):$(VERSION) \
		-f Dockerfile.zenoh-router .

## Build UBI-based zenoh-bridge-ros2dds image (multi-stage: binary extracted from eclipse/zenoh-bridge-ros2dds)
build-bridge:
	podman manifest rm $(BRIDGE_IMAGE):$(VERSION) 2>/dev/null || true
	podman rmi $(BRIDGE_IMAGE):$(VERSION) 2>/dev/null || true
	podman build --platform $(PLATFORM) \
		--build-arg ECLIPSE_TAG=$(ECLIPSE_TAG) \
		--manifest $(BRIDGE_IMAGE):$(VERSION) \
		-f Dockerfile.zenoh-bridge .

## Build both UBI-based Zenoh images
build-ubi: build-router build-bridge

## Push zenoh-router UBI image to Quay.io
push-router:
	podman manifest push --authfile $(AUTHFILE) $(ROUTER_IMAGE):$(VERSION)

## Push zenoh-bridge-ros2dds UBI image to Quay.io
push-bridge:
	podman manifest push --authfile $(AUTHFILE) $(BRIDGE_IMAGE):$(VERSION)

## Build and push both UBI-based Zenoh images to Quay.io
push-ubi: push-router push-bridge

## Mirror upstream Zenoh images to Quay.io verbatim (legacy fallback; prefer build-ubi).
## Copies the upstream Alpine-based binaries without a UBI layer — use only if build-ubi is unavailable.
mirror-bridge:
	skopeo copy --multi-arch all \
		--dest-creds "$(QUAY_USERNAME):$(QUAY_PASSWORD)" \
		docker://docker.io/eclipse/zenoh-bridge-ros2dds:latest \
		docker://quay.io/$(QUAY_ORG)/zenoh-bridge-ros2dds:latest
	skopeo copy --multi-arch all \
		--dest-creds "$(QUAY_USERNAME):$(QUAY_PASSWORD)" \
		docker://docker.io/eclipse/zenoh:latest \
		docker://quay.io/$(QUAY_ORG)/zenoh-router:latest

## Show this help
help:
	@awk '/^## /{if(h=="")h=substr($$0,4);next} /^[a-zA-Z][a-zA-Z0-9_-]+:/{if(h!="")printf "  %-30s %s\n",substr($$1,1,length($$1)-1),h;h="";next}{h=""}' Makefile
	@echo ""
	@echo "Variables (override with make VAR=value):"
	@echo "  QUAY_ORG=$(QUAY_ORG)"
	@echo "  DEMO_ORG=$(DEMO_ORG)"
	@echo "  IMAGE=$(IMAGE)"
	@echo "  ROUTER_IMAGE=$(ROUTER_IMAGE)"
	@echo "  BRIDGE_IMAGE=$(BRIDGE_IMAGE)"
	@echo "  VERSION=$(VERSION)"
	@echo "  ECLIPSE_TAG=$(ECLIPSE_TAG)"
	@echo "  NAMESPACE=$(NAMESPACE)"
	@echo "  BRIDGE_NS=$(BRIDGE_NS)"
	@echo "  PLATFORM=$(PLATFORM)"
