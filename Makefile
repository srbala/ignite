SHELL:=/bin/bash
UID_GID?=$(shell id -u):$(shell id -g)
FIRECRACKER_VERSION:=$(shell cat hack/FIRECRACKER_VERSION)
GO_VERSION=1.12.9
DOCKER_USER?=weaveworks
IMAGE=$(DOCKER_USER)/ignite
GIT_VERSION:=$(shell hack/ldflags.sh --version-only)
IMAGE_DEV_TAG=dev
IMAGE_TAG:=$(shell hack/ldflags.sh --image-tag-only)
# IS_DIRTY is 1 if the tree state is dirty, otherwise 0
IS_DIRTY:=$(shell echo ${GIT_VERSION} | grep -o dirty | wc -l)
PROJECT = github.com/weaveworks/ignite
APIS_DIR = ${PROJECT}/pkg/apis
API_DIRS = ${APIS_DIR}/ignite,${APIS_DIR}/ignite/v1alpha1,${APIS_DIR}/ignite/v1alpha2,${APIS_DIR}/meta/v1alpha1
CACHE_DIR = $(shell pwd)/bin/cache
DOCS_PORT = 8000
# Specifies if this is a CI build or not; if it is, it will save the docker image created to bin/$(GOARCH)/image.tar
IS_CI_BUILD ?= 0
# Unset any GOFLAGS that would interfere with the build
undefine GOFLAGS

## Multi-platform-related stuff
# Ignore GOARCH from the environment for the query, otherwise it results in the environment's GOARCH
GOHOSTARCH := $(shell GOARCH= go env GOARCH 2>/dev/null || echo "amd64")
GOARCH ?= amd64
GOARCH_LIST = amd64 arm64
QEMUVERSION=v2.9.1
# This option is for running docker manifest command
export DOCKER_CLI_EXPERIMENTAL := enabled

ifeq ($(GOARCH),amd64)
QEMUARCH=amd64
BASEIMAGE=alpine:3.9
ARCH_SUFFIX=
endif
ifeq ($(GOARCH),arm64)
QEMUARCH=aarch64
BASEIMAGE=arm64v8/alpine:3.9
ARCH_SUFFIX=-aarch64
endif

all: ignite
install: ignite
	sudo cp bin/$(GOARCH)/ignite /usr/local/bin

BINARIES = ignite ignited ignite-spawn
$(BINARIES):
	$(MAKE) shell COMMAND="make bin/$(GOARCH)/$@"
	# Always update the image when ignite-spawn is updated
	[[ $@ == "ignite-spawn" ]] && $(MAKE) image || exit 0

# Make make execute this target although the file already exists.
.PHONY: bin/$(GOARCH)/ignite bin/$(GOARCH)/ignite-spawn bin/$(GOARCH)/ignited
bin/$(GOARCH)/ignite bin/$(GOARCH)/ignited bin/$(GOARCH)/ignite-spawn: bin/$(GOARCH)/%:
	CGO_ENABLED=0 GOARCH=$(GOARCH) go build -mod=vendor -ldflags "$(shell ./hack/ldflags.sh)" -o bin/$(GOARCH)/$* ./cmd/$*
ifeq ($(GOARCH),$(GOHOSTARCH))
	ln -sf ./$(GOARCH)/$* bin/$*
endif

.PHONY: bin/$(GOARCH)/Dockerfile
image: bin/$(GOARCH)/Dockerfile
bin/$(GOARCH)/Dockerfile: qemu
	sed -e "s|QEMUARCH|$(QEMUARCH)|g;s|BASEIMAGE|$(BASEIMAGE)|g;" Dockerfile > bin/$(GOARCH)/Dockerfile
ifeq ($(GOARCH),amd64)
	# When building for amd64, remove the qemu stuff, it has no part in the amd64 image
	sed -i "/qemu/d" bin/$(GOARCH)/Dockerfile
else
	# Register /usr/bin/qemu-ARCH-static as the handler for non-x86 binaries in the kernel
	docker run --rm --privileged multiarch/qemu-user-static:register --reset
endif
	docker build -t $(IMAGE):${IMAGE_DEV_TAG}-$(GOARCH) \
		--build-arg FIRECRACKER_VERSION=${FIRECRACKER_VERSION} \
		--build-arg ARCH_SUFFIX=${ARCH_SUFFIX} bin/$(GOARCH)
ifeq ($(GOARCH),$(GOHOSTARCH))
	# Only tag the development image if its architecture matches the host
	docker tag $(IMAGE):${IMAGE_DEV_TAG}-$(GOARCH) $(IMAGE):${IMAGE_DEV_TAG}
endif
ifeq ($(IS_DIRTY),0)
	docker tag $(IMAGE):${IMAGE_DEV_TAG}-$(GOARCH) $(IMAGE):${IMAGE_TAG}-$(GOARCH)
ifeq ($(GOARCH),$(GOHOSTARCH))
	# For dev builds for a clean (non-dirty) environment; "simulate" that
	# a manifest list has been built by tagging the docker image
	docker tag $(IMAGE):${IMAGE_TAG}-$(GOARCH) $(IMAGE):${IMAGE_TAG}
endif
endif
ifeq ($(IS_CI_BUILD),1)
	docker save $(IMAGE):${IMAGE_TAG}-$(GOARCH) -o bin/$(GOARCH)/image.tar
endif

build-all: $(addprefix build-all-,$(GOARCH_LIST))
build-all-%:
	$(MAKE) GOARCH=$* $(BINARIES)

push-all: $(addprefix push-all-,$(GOARCH_LIST))
push-all-%:
	$(MAKE) build-all-$*
	docker push $(IMAGE):${IMAGE_TAG}-$*

release: push-all
ifneq ($(IS_DIRTY),0)
	$(error "cannot release dirty tree")
endif
	mkdir -p bin/releases/${GIT_VERSION}
	cp -r bin/{amd64,arm64} bin/releases/${GIT_VERSION}
	docker manifest create --amend $(IMAGE):$(IMAGE_TAG) $(shell echo $(GOARCH_LIST) | sed -e "s~[^ ]*~$(IMAGE):$(IMAGE_TAG)\-&~g")
	@for arch in $(GOARCH_LIST); do docker manifest annotate --arch=$${arch} $(IMAGE):$(IMAGE_TAG) $(IMAGE):$(IMAGE_TAG)-$${arch}; done
	docker manifest push --purge $(IMAGE):$(IMAGE_TAG)

tidy: /go/bin/goimports
	go mod tidy
	go mod vendor
	hack/generate-client.sh
	gofmt -s -w pkg cmd
	goimports -w pkg cmd
	go run hack/cobra.go

tidy-in-docker:
	$(MAKE) shell COMMAND="make tidy"

graph:
	hack/graph.sh

api-docs: godoc2md
	cd pkg/apis/ && for gv in */v1*; do \
		GROUPVERSION=$$gv GROUP_VERSION=$$(echo $$gv | sed 's|/|_|g') \
		$(MAKE) -C ../../ api-doc; done

api-doc:
	mkdir -p docs/api bin/tmp/${GROUPVERSION}
	mv $(shell pwd)/pkg/apis/${GROUPVERSION}/zz_generated* bin/tmp/${GROUPVERSION}
	$(MAKE) shell COMMAND="godoc2md /go/src/${PROJECT}/pkg/apis/${GROUPVERSION} > bin/tmp/${GROUP_VERSION}.md"
	sed -e "s|src/target|pkg/apis/${GROUPVERSION}|g;s|/go/src/||g" -i bin/tmp/${GROUP_VERSION}.md
	sed -e "s|(/pkg/apis|(https://github.com/weaveworks/ignite/tree/master/pkg/apis|g" -i bin/tmp/${GROUP_VERSION}.md
	mv bin/tmp/${GROUPVERSION}/*.go $(shell pwd)/pkg/apis/${GROUPVERSION}/
	rm -r bin/tmp/${GROUPVERSION}
	# Format the docs with pandoc
	docker run -it --rm \
		-v $(shell pwd):/data \
		-u $(shell id -u):$(shell id -g) \
		pandoc/core \
			--from markdown \
			--to gfm \
			bin/tmp/${GROUP_VERSION}.md > docs/api/${GROUP_VERSION}.md

shell:
	mkdir -p $(CACHE_DIR)/go $(CACHE_DIR)/cache
	docker run -it --rm \
		-v $(CACHE_DIR)/go:/go \
		-v $(CACHE_DIR)/cache:/.cache/go-build \
		-v $(shell pwd):/go/src/${PROJECT} \
		-w /go/src/${PROJECT} \
		-u $(shell id -u):$(shell id -g) \
		-e GO111MODULE=on \
		-e GOARCH=$(GOARCH) \
		golang:$(GO_VERSION) \
		$(COMMAND)

autogen: api-docs
	$(MAKE) shell COMMAND="make dockerized-autogen"

dockerized-autogen: /go/bin/deepcopy-gen /go/bin/defaulter-gen /go/bin/conversion-gen /go/bin/openapi-gen
	# Let the boilerplate be empty
	touch /tmp/boilerplate
	/go/bin/deepcopy-gen \
		--input-dirs ${API_DIRS} \
		--bounding-dirs ${APIS_DIR} \
		-O zz_generated.deepcopy \
		-h /tmp/boilerplate 

	/go/bin/defaulter-gen \
		--input-dirs ${API_DIRS} \
		-O zz_generated.defaults \
		-h /tmp/boilerplate

	/go/bin/conversion-gen \
		--input-dirs ${API_DIRS} \
		-O zz_generated.conversion \
		-h /tmp/boilerplate
	
	/go/bin/openapi-gen \
		--input-dirs ${API_DIRS} \
		--output-package ${PROJECT}/pkg/openapi \
		--report-filename pkg/openapi/violations.txt \
		-h /tmp/boilerplate

/go/bin/%: vendor
	go install k8s.io/code-generator/cmd/$*

/go/bin/openapi-gen:
	go install k8s.io/kube-openapi/cmd/openapi-gen

godoc2md: bin/cache/go/bin/godoc2md
bin/cache/go/bin/godoc2md:
	mkdir -p $$(dirname $@)
	curl -sSL https://github.com/luxas/godoc2md/releases/download/v0.1.0/godoc2md > $@
	chmod +x $@

/go/bin/goimports:
	go get golang.org/x/tools/cmd/goimports

# QEMU stuff
qemu: bin/$(GOARCH)/qemu-$(QEMUARCH)-static
bin/$(GOARCH)/qemu-$(QEMUARCH)-static:
	mkdir -p bin/$(GOARCH)
ifneq ($(GOARCH),amd64)
	curl -sSL https://github.com/multiarch/qemu-user-static/releases/download/$(QEMUVERSION)/x86_64_qemu-$(QEMUARCH)-static.tar.gz | tar -xz -C bin/$(GOARCH)
	chmod 0755 $@
endif

# Read the docs stuff
bin/docs/builder-image.tar:
	mkdir -p bin/docs
	docker build -t ignite-docs-builder -f docs/Dockerfile.build docs
	docker save ignite-docs-builder -o $@

build-docs: bin/docs/builder-image.tar
	docker load -i bin/docs/builder-image.tar
	docker build -t ignite-docs docs

test-docs: build-docs
	docker run -it --rm ignite-docs /usr/bin/linkchecker _build/html/index.html

serve-docs: build-docs
	@echo Stating docs website on http://localhost:${DOCS_PORT}/_build/html/index.html
	@docker run -i --rm -p ${DOCS_PORT}:8000 -e USER_ID=$$UID ignite-docs
