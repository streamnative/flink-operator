VERSION ?= 0.0.1

# Image URL to use all building/pushing image targets
IMG ?= gcr.io/flink-operator/flink-operator:latest
UPSTREAM_IMG ?= gcr.io/flink-operator/flink-operator@sha256:af78aef1e6ca3e082f5d03b53db09fe0d31e21424ac87c9f0204b3739001d3cc
# Produce CRDs that work back to Kubernetes 1.11 (no version conversion)
#CRD_OPTIONS ?= "crd:maxDescLen=0,trivialVersions=true"
CRD_OPTIONS ?= "crd:maxDescLen=0"
# The Kubernetes namespace in which the operator will be deployed.
FLINK_OPERATOR_NAMESPACE ?= flink-operator-system
# Prefix for Kubernetes resource names. When deploying multiple operators, make sure that the names of cluster-scoped resources are not duplicated.
RESOURCE_PREFIX ?= flink-operator-
# The Kubernetes namespace to limit watching.
WATCH_NAMESPACE ?=

GREEN=\033[1;32m
RED=\033[1;31m
RESET=\033[0m

# Default bundle image tag
BUNDLE_IMG ?= controller-bundle:$(VERSION)
# Options for 'bundle-build'
ifneq ($(origin CHANNELS), undefined)
BUNDLE_CHANNELS := --channels=$(CHANNELS)
endif
ifneq ($(origin DEFAULT_CHANNEL), undefined)
BUNDLE_DEFAULT_CHANNEL := --default-channel=$(DEFAULT_CHANNEL)
endif
BUNDLE_METADATA_OPTS ?= $(BUNDLE_CHANNELS) $(BUNDLE_DEFAULT_CHANNEL)
# Bases for bundle manifests
BUNDLE_MANIFESTS_BASES=config/manifests
BUNDLE_MANIFESTS ?= $(BUNDLE_MANIFESTS_BASES)
KUBE_RBAC_PROXY_IMG ?= gcr.io/kubebuilder/kube-rbac-proxy:v0.5.0

#################### Local build and test ####################

# Build the flink-operator binary
build: generate fmt vet
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 GO111MODULE=on go build -a -o bin/flink-operator main.go
	go mod tidy

# Run tests.
test: generate fmt vet manifests
	go test ./... -coverprofile cover.out
	go mod tidy
	echo $(FLINK_OPERATOR_NAMESPACE)

# Run tests in the builder container.
test-in-docker: builder-image
	docker run flink-operator-builder make test

# Run against the configured Kubernetes cluster in ~/.kube/config
run: generate fmt vet
	go run ./main.go
	go mod tidy

# Generate manifests e.g. CRD, RBAC etc.
manifests: controller-gen
	$(CONTROLLER_GEN) $(CRD_OPTIONS) rbac:roleName=manager-role webhook paths="./api/v1beta1/..." output:crd:artifacts:config=config/crd/bases
	go mod tidy

# Run go fmt against code
fmt:
	go fmt ./...

# Run go vet against code
vet:
	go vet ./...

# Generate code
generate: controller-gen
	$(CONTROLLER_GEN) object:headerFile=./hack/boilerplate.go.txt paths=./api/v1beta1/...

CONTROLLER_GEN = $(shell pwd)/bin/controller-gen
controller-gen: ## Download controller-gen locally if necessary.
	$(call go-get-tool,$(CONTROLLER_GEN),sigs.k8s.io/controller-tools/cmd/controller-gen@v0.8.0)

KUSTOMIZE = $(shell pwd)/bin/kustomize
kustomize: ## Download kustomize locally if necessary.
	$(call go-get-tool,$(KUSTOMIZE),sigs.k8s.io/kustomize/kustomize/v4@v4.5.2)

# go-get-tool will 'go get' any package $2 and install it to $1.
PROJECT_DIR := $(shell dirname $(abspath $(lastword $(MAKEFILE_LIST))))
define go-get-tool
@[ -f $(1) ] || { \
set -e ;\
TMP_DIR=$$(mktemp -d) ;\
cd $$TMP_DIR ;\
go mod init tmp ;\
echo "Downloading $(2)" ;\
GOBIN=$(PROJECT_DIR)/bin go install $(2) ;\
rm -rf $$TMP_DIR ;\
}
endef


#################### Docker image ####################

# Builder image which builds the flink-operator binary from the source code.
builder-image:
	docker build -t flink-operator-builder -f Dockerfile.builder .

# Build the Flink Operator docker image
operator-image: builder-image # test-in-docker
	docker build  -t ${IMG} --label git-commit=$(shell git rev-parse HEAD) .
	@echo "updating kustomize image patch file for Flink Operator resource"

# Push the Flink Operator docker image to container registry.
push-operator-image:
	docker push ${IMG}

docker-build: operator-image

# Push the docker image
docker-push:
	docker push ${IMG}

#################### Deployment ####################

# Install CRDs into a cluster
install: manifests
	kubectl apply -f config/crd/bases

# Deploy cert-manager which is required by webhooks of the operator.
webhook-cert:
	bash scripts/generate_cert.sh --service $(RESOURCE_PREFIX)webhook-service --secret webhook-server-cert -n $(FLINK_OPERATOR_NAMESPACE)

config/default/manager_image_patch.yaml:
	cp config/default/manager_image_patch.template config/default/manager_image_patch.yaml

# Build kustomize overlay for deploy/undeploy.
build-overlay:
	rm -rf config/deploy && cp -rf config/default config/deploy && cd config/deploy \
			&& kustomize edit set nameprefix $(RESOURCE_PREFIX) \
			&& kustomize edit set namespace $(FLINK_OPERATOR_NAMESPACE)
ifneq ($(WATCH_NAMESPACE),)
	cd config/deploy \
			&& sed -E -i.bak  "s/(\-\-watch\-namespace\=)/\1$(WATCH_NAMESPACE)/" manager_auth_proxy_patch.yaml \
			&& kustomize edit add patch webhook_namespace_selector_patch.yaml \
			|| true
endif
	sed -E -i.bak "s/resources:/bases:/" config/deploy/kustomization.yaml
	rm config/deploy/*.bak

# Generate deploy template.
template: build-overlay
	kubectl kustomize config/deploy \
			| sed -e "s/$(RESOURCE_PREFIX)system/$(FLINK_OPERATOR_NAMESPACE)/g"

# Deploy the operator in the configured Kubernetes cluster in ~/.kube/config
deploy: install webhook-cert config/default/manager_image_patch.yaml build-overlay
	sed -e 's#image: .*#image: '"$(IMG)"'#' ./config/deploy/manager_image_patch.template >./config/deploy/manager_image_patch.yaml
	@echo "Getting webhook server certificate"
	$(eval CA_BUNDLE := $(shell kubectl get secrets/webhook-server-cert -n $(FLINK_OPERATOR_NAMESPACE) -o jsonpath="{.data.tls\.crt}"))
	kubectl kustomize config/deploy \
			| sed -e "s/$(RESOURCE_PREFIX)system/$(FLINK_OPERATOR_NAMESPACE)/g" \
			| sed -e "s/Cg==/$(CA_BUNDLE)/g" \
			| kubectl apply -f -
ifneq ($(WATCH_NAMESPACE),)
    # Set the label on watch-target namespace to support webhook namespaceSelector.
	kubectl label ns $(WATCH_NAMESPACE) flink-operator-namespace=$(FLINK_OPERATOR_NAMESPACE)
endif
	@printf "$(GREEN)Flink Operator deployed, image=$(IMG), operator_namespace=$(FLINK_OPERATOR_NAMESPACE), watch_namespace=$(WATCH_NAMESPACE)$(RESET)\n"

undeploy-crd:
	kubectl delete -f config/crd/bases

undeploy-controller: build-overlay
	kubectl kustomize config/deploy \
			| sed -e "s/$(RESOURCE_PREFIX)system/$(FLINK_OPERATOR_NAMESPACE)/g" \
			| kubectl delete -f - \
			|| true
ifneq ($(WATCH_NAMESPACE),)
    # Remove the label, which is set when operator is deployed to support webhook namespaceSelector
	kubectl label ns $(WATCH_NAMESPACE) flink-operator-namespace-
endif

undeploy: undeploy-controller undeploy-crd
	@printf "$(GREEN)Flink Operator undeployed, namespace=$(FLINK_OPERATOR_NAMESPACE)$(RESET)\n"

# Deploy the sample Flink clusters in the Kubernetes cluster
samples:
	kubectl apply -f config/samples/

# Generate bundle manifests and metadata, then validate generated files.
bundle: kustomize
	operator-sdk generate kustomize manifests -q
	cd config/manager && $(KUSTOMIZE) edit set image flink-operator=$(IMG)
	cd config/manager && $(KUSTOMIZE) edit add patch --group apps --version v1 --kind Deployment --name controller-manager \
			--patch '[{"op": "add", "path": "/spec/template/metadata/labels/service.istio.io~1canonical-revision", "value": "$(VERSION)"}]'
	cd config/default && $(KUSTOMIZE) edit set image gcr.io/kubebuilder/kube-rbac-proxy=$(KUBE_RBAC_PROXY_IMG)
	$(KUSTOMIZE) build config/manifests | operator-sdk generate bundle -q --overwrite --version $(VERSION) $(BUNDLE_METADATA_OPTS)
	operator-sdk bundle validate ./bundle

# Build the bundle image.
bundle-build:
	docker build -f bundle.Dockerfile -t $(BUNDLE_IMG) .

bundle-push:
	docker push $(BUNDLE_IMG)
