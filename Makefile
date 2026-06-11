IMAGE         ?= quay.io/jianrzha/ros2-zenoh-demo
GAZEBO_IMAGE  ?= quay.io/jianrzha/ros2-zenoh-gazebo
VERSION       ?= 0.0.1
NAMESPACE     ?= ros2-zenoh
BRIDGE_NS     ?= ros2-zenoh-bridge
GAZEBO_NS     ?= ros2-zenoh-gazebo
PLATFORM      ?= linux/amd64,linux/arm64
AUTHFILE      ?= $(HOME)/.config/containers/auth.json

.PHONY: all build push deploy undeploy test demo logs \
        deploy-bridge undeploy-bridge test-bridge demo-bridge logs-bridge \
        mirror-bridge \
        build-gazebo push-gazebo deploy-gazebo undeploy-gazebo \
        test-gazebo demo-gazebo logs-gazebo \
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

## Mirror upstream Zenoh images to Quay.io (requires QUAY_USERNAME / QUAY_PASSWORD env vars)
mirror-bridge:
	skopeo copy --multi-arch all \
		--dest-creds "$(QUAY_USERNAME):$(QUAY_PASSWORD)" \
		docker://docker.io/eclipse/zenoh-bridge-ros2dds:latest \
		docker://quay.io/jianrzha/zenoh-bridge-ros2dds:latest
	skopeo copy --multi-arch all \
		--dest-creds "$(QUAY_USERNAME):$(QUAY_PASSWORD)" \
		docker://docker.io/eclipse/zenoh:latest \
		docker://quay.io/jianrzha/zenoh-router:latest

## Build the Gazebo simulation container image
build-gazebo:
	podman build --platform $(PLATFORM) -t $(GAZEBO_IMAGE):$(VERSION) -f Dockerfile.gazebo .

## Push the Gazebo image to Quay.io
push-gazebo:
	podman push --authfile $(AUTHFILE) $(GAZEBO_IMAGE):$(VERSION)

## Apply Gazebo simulation manifests, substituting GAZEBO_IMAGE:VERSION
deploy-gazebo:
	kubectl apply -f k8s/gazebo/namespace.yaml
	@for f in k8s/gazebo/configmap-*.yaml k8s/gazebo/service-*.yaml k8s/gazebo/deployment-*.yaml; do \
		sed 's|$(GAZEBO_IMAGE):latest|$(GAZEBO_IMAGE):$(VERSION)|g' $$f | kubectl apply -f -; \
	done

## Remove the Gazebo namespace and all contained resources
undeploy-gazebo:
	kubectl delete namespace $(GAZEBO_NS) --ignore-not-found

## Wait for rollout then run Gazebo pipeline verification
test-gazebo:
	kubectl rollout status deployment/zenoh-router -n $(GAZEBO_NS) --timeout=120s
	kubectl rollout status deployment/gazebo-sim   -n $(GAZEBO_NS) --timeout=300s
	NAMESPACE=$(GAZEBO_NS) bash scripts/verify-gazebo.sh

## Live-stream all Gazebo simulation pod logs (Ctrl-C to stop)
demo-gazebo:
	NAMESPACE=$(GAZEBO_NS) bash scripts/demo-gazebo.sh

## Stream raw logs from all Gazebo pods (Ctrl-C to stop)
logs-gazebo:
	@kubectl logs -n $(GAZEBO_NS) -l app=zenoh-router              --prefix --tail=3 &
	@kubectl logs -n $(GAZEBO_NS) -l app=gazebo-sim -c gazebo-sim   --prefix --tail=3 &
	@kubectl logs -n $(GAZEBO_NS) -l app=gazebo-sim -c ros-gz-bridge --prefix --tail=3 &
	@kubectl logs -n $(GAZEBO_NS) -l app=gazebo-sim -c zenoh-bridge  --prefix -f

## Show this help
help:
	@grep -E '^## ' Makefile | sed 's/## /  /'
	@echo ""
	@echo "Variables (override with make VAR=value):"
	@echo "  IMAGE=$(IMAGE)"
	@echo "  GAZEBO_IMAGE=$(GAZEBO_IMAGE)"
	@echo "  VERSION=$(VERSION)"
	@echo "  NAMESPACE=$(NAMESPACE)"
	@echo "  BRIDGE_NS=$(BRIDGE_NS)"
	@echo "  GAZEBO_NS=$(GAZEBO_NS)"
	@echo "  PLATFORM=$(PLATFORM)"
