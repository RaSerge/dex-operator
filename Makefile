SOURCES_DIRS    = cmd pkg
SOURCES_DIRS_GO = ./pkg/... ./cmd/...
SOURCES_API_DIR = ./pkg/apis/kubic

GO         := GO111MODULE=on GO15VENDOREXPERIMENT=1 go
GO_NOMOD   := GO111MODULE=off go
GO_VERSION := $(shell $(GO) version | sed -e 's/^[^0-9.]*\([0-9.]*\).*/\1/')

# go source files, ignore vendor directory
DEX_OPER_SRCS      = $(shell find $(SOURCES_DIRS) -type f -name '*.go' -not -path "*generated*")
DEX_OPER_MAIN_SRCS = $(shell find $(SOURCES_DIRS) -type f -name '*.go' -not -path "*_test.go")

DEX_OPER_GEN_SRCS       = $(shell grep -l -r "//go:generate" $(SOURCES_DIRS) 2>/dev/null)
DEX_OPER_CRD_TYPES_SRCS = $(shell find $(SOURCES_API_DIR) -type f -name "*_types.go")

DEX_OPER_EXE  = cmd/dex-operator/dex-operator
DEX_OPER_MAIN = cmd/dex-operator/main.go
.DEFAULT_GOAL: $(DEX_OPER_EXE)

IMAGE_BASENAME = dex-operator
IMAGE_NAME     = opensuse/$(IMAGE_BASENAME)
IMAGE_TAR_GZ   = $(IMAGE_BASENAME)-latest.tar.gz
IMAGE_DEPS     = $(DEX_OPER_EXE) Dockerfile

# should be non-empty when these exes are installed
DEP_EXE       := $(shell command -v dep 2> /dev/null)
KUSTOMIZE_EXE := $(shell command -v kustomize 2> /dev/null)

# These will be provided to the target
DEX_OPER_VERSION := 1.0.0
DEX_OPER_BUILD   := `git rev-parse HEAD 2>/dev/null`

# Use linker flags to provide version/build settings to the target
DEX_OPER_LDFLAGS = -ldflags "-X=main.Version=$(DEX_OPER_VERSION) -X=main.Build=$(DEX_OPER_BUILD)"

# sudo command (and version passing env vars)
SUDO = sudo
SUDO_E = $(SUDO) -E

# the default kubeconfig program generated by kubeadm (used for running things locally)
KUBECONFIG = /etc/kubernetes/admin.conf

# the deployment manifest for the operator
DEX_DEPLOY = deployments/dex-operator-full.yaml

# the kubebuilder generator
CONTROLLER_GEN := sigs.k8s.io/controller-tools/cmd/controller-gen

# increase to 8 for detailed kubeadm logs...
# Example: make local-run VERBOSE_LEVEL=8
VERBOSE_LEVEL = 5

CONTAINER_VOLUMES = \
        -v /sys/fs/cgroup:/sys/fs/cgroup \
        -v /var/run:/var/run

#############################################################
# Build targets
#############################################################

all: $(DEX_OPER_EXE)

#
# NOTE: we are currently not using the RBAC rules generated by kubebuilder:
#       we are just assigning the "cluster-admin" role to the manager (as we
#       must generate ClusterRoles/ClusterRoleBindings)
# TODO: investigate if we can reduce these privileges...
#
# manifests-rbac:
# 	@echo ">>> Creating RBAC manifests..."
# 	@rm -rf config/rbac/*.yaml
# 	@go run $(CONTROLLER_GEN) rbac --name $(CONTROLLER_GEN_RBAC_NAME)
#

# Generate manifests e.g. CRD, RBAC etc.
manifests: $(DEX_DEPLOY)

#############################################################
# Analyze targets
#############################################################

.PHONY: fmt
fmt: $(DEX_OPER_SRCS)
	@echo ">>> Reformatting code"
	@$(GO) fmt $(SOURCES_DIRS_GO)

.PHONY: simplify
simplify:
	@gofmt -s -l -w $(DEX_OPER_SRCS)

.PHONY: golint
golint:
	-@$(GO_NOMOD) get -u golang.org/x/lint/golint

.PHONY: check
check: fmt golint
	@for d in $$($(GO) list ./... | grep -v /vendor/); do golint -set_exit_status $${d}; done
	@$(GO) tool vet ${DEX_OPER_SRCS}

.PHONY: test
test:
	@$(GO) test -race -short -v $(SOURCES_DIRS_GO) -coverprofile cover.out

.PHONY: integration
integration: controller-gen
	@$(GO) test -v $(SOURCES_DIRS_GO) -coverprofile cover.out

.PHONY: clean
clean: docker-image-clean
	rm -f $(DEX_OPER_EXE) go.sum

.PHONY: coverage
coverage:
	$(GO_NOMOD) tool cover -html=cover.out

#############################################################
# Some simple run targets
# (for testing things locally)
#############################################################

# assuming the k8s cluster is accessed with $(KUBECONFIG),
# deploy the dex-operator manifest file in this cluster.
local-deploy: $(DEX_DEPLOY) docker-image-local
	@echo ">>> (Re)deploying..."
	@[ -r $(KUBECONFIG) ] || $(SUDO_E) chmod 644 $(KUBECONFIG)
	@echo ">>> Deleting any previous resources..."
	-@kubectl get ldapconnectors -o jsonpath="{..metadata.name}" | \
		xargs -r kubectl delete --all=true ldapconnector 2>/dev/null
	-@kubectl get dexconfigurations -o jsonpath="{..metadata.name}" | \
		xargs -r kubectl delete --all=true dexconfiguration 2>/dev/null
	@sleep 30
	-@kubectl delete --all=true --cascade=true -f $(DEX_DEPLOY) 2>/dev/null
	@echo ">>> Regenerating manifests..."
	@make manifests
	@echo ">>> Loading manifests..."
	kubectl apply --kubeconfig $(KUBECONFIG) -f $(DEX_DEPLOY)

clean-local-deploy:
	@make manifests
	@echo ">>> Uninstalling manifests..."
	kubectl delete --kubeconfig $(KUBECONFIG) -f $(DEX_DEPLOY)

# Usage:
# - Run it locally:
#   make local-run VERBOSE_LEVEL=5
# - Start a Deployment with the manager:
#   make local-run EXTRA_ARGS="--"
#
local-run: $(DEX_OPER_EXE) manifests
	[ -r $(KUBECONFIG) ] || $(SUDO_E) chmod 644 $(KUBECONFIG)
	@echo ">>> Running $(DEX_OPER_EXE) as _root_"
	$(DEX_OPER_EXE) manager \
		-v $(VERBOSE_LEVEL) \
		--kubeconfig $(KUBECONFIG) \
		$(EXTRA_ARGS)

docker-run: $(IMAGE_TAR_GZ)
	@echo ">>> Running $(IMAGE_NAME):latest in the local Docker"
	docker run -it --rm \
		--privileged=true \
		--net=host \
		--security-opt seccomp:unconfined \
		--cap-add=SYS_ADMIN \
		--name=$(IMAGE_BASENAME) \
		$(CONTAINER_VOLUMES) \
		$(IMAGE_NAME):latest $(EXTRA_ARGS)

docker-image-local: local-$(IMAGE_TAR_GZ)

docker-image: $(IMAGE_TAR_GZ)
docker-image-clean:
	-[ -f $(IMAGE_NAME) ] && docker rmi $(IMAGE_NAME)
	rm -f $(IMAGE_TAR_GZ)

#############################################################
# Support targets
#############################################################

kustomize-deps:
ifndef KUSTOMIZE_EXE
	@echo ">>> kustomize does not seem to be installed. installing kustomize..."
	$(GO) get -u sigs.k8s.io/kustomize
endif

# NOTE: deepcopy-gen doesn't support go1.11's modules, so we must 'go get' it
deepcopy-deps:
	@echo ">>> Getting deepcopy-gen"
	-@$(GO_NOMOD) get -u k8s.io/code-generator/cmd/deepcopy-gen

generate: $(DEX_OPER_GEN_SRCS) deepcopy-deps
	@echo ">>> Generating files..."
	@$(GO) generate -x $(SOURCES_DIRS_GO)

$(DEX_OPER_EXE): $(DEX_OPER_MAIN_SRCS) generate
	@echo ">>> Building $(DEX_OPER_EXE)..."
	$(GO) build $(DEX_OPER_LDFLAGS) -o $(DEX_OPER_EXE) $(DEX_OPER_MAIN)

controller-gen: $(DEX_OPER_CRD_TYPES_SRCS)
	@echo ">>> Creating manifests..."
	@$(GO) run $(CONTROLLER_GEN) all

$(DEX_DEPLOY): kustomize-deps controller-gen
	@echo ">>> Collecting all the manifests for generating $(DEX_DEPLOY)..."
	@rm -f $(DEX_DEPLOY)
	@echo "#" >> $(DEX_DEPLOY)
	@echo "# DO NOT EDIT! Generated automatically with 'make $(DEX_DEPLOY)'" >> $(DEX_DEPLOY)
	@echo "#              from files in 'config/*'" >> $(DEX_DEPLOY)
	@echo "#" >> $(DEX_DEPLOY)
	@for i in $(shell find config/sas config/crds -name '*.yaml') ; do \
		echo -e "\n---" >> $(DEX_DEPLOY) ; \
		cat $$i >> $(DEX_DEPLOY) ; \
	done
	@echo -e "\n---" >> $(DEX_DEPLOY)
	@kustomize build config/default >> $(DEX_DEPLOY)

local-$(IMAGE_TAR_GZ): $(DEX_OPER_EXE)
	@echo ">>> Creating Docker image (Local build)..."
	docker build -f Dockerfile.local \
		--build-arg BUILT_EXE=$(DEX_OPER_EXE) \
		-t $(IMAGE_NAME):latest .
	@echo ">>> Creating tar for image (Local build)"
	docker save $(IMAGE_NAME):latest | gzip > local-$(IMAGE_TAR_GZ)

$(IMAGE_TAR_GZ):
	@echo ">>> Creating Docker image..."
	docker build -t $(IMAGE_NAME):latest .
	@echo ">>> Creating tar for image..."
	docker save $(IMAGE_NAME):latest | gzip > $(IMAGE_TAR_GZ)

# this target should not be necessary: Go 1.11 will download things on demand.
# however, this is useful in Circle-CI as the dependencies are already cached
# this will create the `vendor` from that cache and copy it to the `docker build`
_vendor-download:
	@echo ">>> Downloading vendors"
	$(GO) mod vendor

#############################################################
# Other stuff
#############################################################

-include Makefile.local
