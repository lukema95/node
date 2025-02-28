.PHONY: build

PACKAGE_NAME := github.com/zeta-chain/node
NODE_VERSION := $(shell ./version.sh)
NODE_COMMIT := $(shell [ -z "${NODE_COMMIT}" ] && git log -1 --format='%H' || echo ${NODE_COMMIT} )
DOCKER ?= docker
# allow setting of NODE_COMPOSE_ARGS to pass additional args to docker compose
# useful for setting profiles and/ort optional overlays
# example: NODE_COMPOSE_ARGS="--profile monitoring -f docker-compose-persistent.yml"
DOCKER_COMPOSE ?= $(DOCKER) compose -f docker-compose.yml $(NODE_COMPOSE_ARGS)
DOCKER_BUF := $(DOCKER) run --rm -v $(CURDIR):/workspace --workdir /workspace bufbuild/buf
GOFLAGS := ""
GOPATH ?= '$(HOME)/go'

# common goreaser command definition
GOLANG_CROSS_VERSION ?= v1.22.7@sha256:24b2d75007f0ec8e35d01f3a8efa40c197235b200a1a91422d78b851f67ecce4
GORELEASER := $(DOCKER) run \
	--rm \
	--privileged \
	-e CGO_ENABLED=1 \
	-v /var/run/docker.sock:/var/run/docker.sock \
	-v `pwd`:/go/src/$(PACKAGE_NAME) \
	-w /go/src/$(PACKAGE_NAME) \
	-e "GITHUB_TOKEN=${GITHUB_TOKEN}" \
	ghcr.io/goreleaser/goreleaser-cross:${GOLANG_CROSS_VERSION}

ldflags = -X github.com/cosmos/cosmos-sdk/version.Name=zetacore \
	-X github.com/cosmos/cosmos-sdk/version.ServerName=zetacored \
	-X github.com/cosmos/cosmos-sdk/version.ClientName=zetaclientd \
	-X github.com/cosmos/cosmos-sdk/version.Version=$(NODE_VERSION) \
	-X github.com/cosmos/cosmos-sdk/version.Commit=$(NODE_COMMIT) \
	-X github.com/cosmos/cosmos-sdk/types.DBBackend=pebbledb \
	-X github.com/zeta-chain/node/pkg/constant.Name=zetacored \
	-X github.com/zeta-chain/node/pkg/constant.Version=$(NODE_VERSION) \
	-X github.com/zeta-chain/node/pkg/constant.CommitHash=$(NODE_COMMIT) \
	-buildid= \
	-s -w

BUILD_FLAGS := -ldflags '$(ldflags)' -tags pebbledb,ledger

TEST_DIR ?= "./..."
TEST_BUILD_FLAGS := -tags pebbledb,ledger

export DOCKER_BUILDKIT := 1

# parameters for localnet docker compose files
# set defaults to empty to prevent docker warning
export E2E_ARGS := $(E2E_ARGS)

clean: clean-binaries clean-dir clean-test-dir clean-coverage

clean-binaries:
	@rm -rf ${GOBIN}/zetacored
	@rm -rf ${GOBIN}/zetaclientd

clean-dir:
	@rm -rf ~/.zetacored
	@rm -rf ~/.zetacore

all: install

go.sum: go.mod
		@echo "--> Ensure dependencies have not been modified"
		GO111MODULE=on go mod verify

###############################################################################
###                             Test commands                               ###
###############################################################################

test: clean-test-dir run-test

run-test:
	@go test ${TEST_BUILD_FLAGS} ${TEST_DIR}

# Generate the test coverage
# "|| exit 1" is used to return a non-zero exit code if the tests fail
test-coverage:
	@go test ${TEST_BUILD_FLAGS} -coverprofile coverage.out ${TEST_DIR} || exit 1

coverage-report: test-coverage
	@go tool cover -html=coverage.out -o coverage.html

clean-coverage:
	@rm -f coverage.out
	@rm -f coverage.html

clean-test-dir:
	@rm -rf x/crosschain/client/integrationtests/.zetacored
	@rm -rf x/crosschain/client/querytests/.zetacored
	@rm -rf x/observer/client/querytests/.zetacored

###############################################################################
###                          Install commands                               ###
###############################################################################

build-testnet-ubuntu: go.sum
		docker build -t zetacore-ubuntu --platform linux/amd64 -f ./Dockerfile-athens3-ubuntu .
		docker create --name temp-container zetacore-ubuntu
		docker cp temp-container:/go/bin/zetaclientd .
		docker cp temp-container:/go/bin/zetacored .
		docker rm temp-container

install: go.sum
		@echo "--> Installing zetacored, zetaclientd, and zetaclientd-supervisor"
		@go install -mod=readonly $(BUILD_FLAGS) ./cmd/zetacored
		@go install -mod=readonly $(BUILD_FLAGS) ./cmd/zetaclientd
		@go install -mod=readonly $(BUILD_FLAGS) ./cmd/zetaclientd-supervisor

install-zetaclient: go.sum
		@echo "--> Installing zetaclientd"
		@go install -mod=readonly $(BUILD_FLAGS) ./cmd/zetaclientd

install-zetacore: go.sum
		@echo "--> Installing zetacored"
		@go install -mod=readonly $(BUILD_FLAGS) ./cmd/zetacored

# running with race detector on will be slow
install-zetaclient-race-test-only-build: go.sum
		@echo "--> Installing zetaclientd"
		@go install -race -mod=readonly $(BUILD_FLAGS) ./cmd/zetaclientd

install-zetatool: go.sum
		@echo "--> Installing zetatool"
		@go install -mod=readonly $(BUILD_FLAGS) ./cmd/zetatool

###############################################################################
###                             Local network                               ###
###############################################################################

init:
	./standalone-network/init.sh

run:
	./standalone-network/run.sh

chain-init: clean install-zetacore init
chain-run: clean install-zetacore init run
chain-stop:
	@killall zetacored
	@killall tail

test-cctx:
	./standalone-network/cctx-creator.sh

###############################################################################
###                                 Linting            	                    ###
###############################################################################

lint-pre:
	@test -z $(gofmt -l .)
	@GOFLAGS=$(GOFLAGS) go mod verify

lint: lint-pre
	@golangci-lint run

lint-gosec:
	@bash ./scripts/gosec.sh

gosec:
	gosec  -exclude-dir=localnet ./...

###############################################################################
###                           		Formatting			                    ###
###############################################################################

fmt:
	@bash ./scripts/fmt.sh

###############################################################################
###                           Generation commands  		                    ###
###############################################################################

protoVer=0.13.0
protoImageName=ghcr.io/cosmos/proto-builder:$(protoVer)
protoImage=$(DOCKER) run --rm -v $(CURDIR):/workspace --workdir /workspace --user $(shell id -u):$(shell id -g) $(protoImageName)

proto-format:
	@echo "--> Formatting Protobuf files"
	@$(protoImage) find ./ -name "*.proto" -exec clang-format -i {} \;
.PHONY: proto-format

typescript: proto-format
	@echo "--> Generating TypeScript bindings"
	@bash ./scripts/protoc-gen-typescript.sh
.PHONY: typescript

proto-gen: proto-format
	@echo "--> Removing old Go types "
	@find . -name '*.pb.go' -type f -delete
	@echo "--> Generating Protobuf files"
	@$(protoImage) sh ./scripts/protoc-gen-go.sh

openapi: proto-format
	@echo "--> Generating OpenAPI specs"
	@bash ./scripts/protoc-gen-openapi.sh
.PHONY: openapi

specs:
	@echo "--> Generating module documentation"
	@go run ./scripts/gen-spec.go
.PHONY: specs

docs-zetacored:
	@echo "--> Generating zetacored documentation"
	@bash ./scripts/gen-docs-zetacored.sh
.PHONY: docs-zetacored

mocks:
	@echo "--> Generating mocks"
	@bash ./scripts/mocks-generate.sh
.PHONY: mocks

precompiles:
	@echo "--> Generating bindings for precompiled contracts"
	@bash ./scripts/bindings-stateful-precompiles.sh
.PHONY: precompiles

# generate also includes Go code formatting
generate: proto-gen openapi specs typescript docs-zetacored mocks precompiles fmt
.PHONY: generate


###############################################################################
###                         Localnet                          				###
###############################################################################
e2e-images: zetanode orchestrator
start-localnet: e2e-images start-localnet-skip-build

start-localnet-skip-build:
	@echo "--> Starting localnet"
	export LOCALNET_MODE=setup-only && \
	cd contrib/localnet/ && $(DOCKER_COMPOSE) up -d

# stop-localnet should include all profiles so other containers are also removed
stop-localnet:
	cd contrib/localnet/ && $(DOCKER_COMPOSE) --profile all down --remove-orphans

# delete any volume ending in persist
clear-localnet-persistence:
	docker volume rm $(docker volume ls -qf "label=localnet=true")

###############################################################################
###                         E2E tests               						###
###############################################################################

ifdef ZETANODE_IMAGE
zetanode:
	@echo "Pulling zetanode image"
	$(DOCKER) pull $(ZETANODE_IMAGE)
	$(DOCKER) tag $(ZETANODE_IMAGE) zetanode:latest
.PHONY: zetanode
else
zetanode:
	@echo "Building zetanode"
	$(DOCKER) build -t zetanode --build-arg NODE_VERSION=$(NODE_VERSION) --build-arg NODE_COMMIT=$(NODE_COMMIT) --target latest-runtime -f ./Dockerfile-localnet .
.PHONY: zetanode
endif

orchestrator:
	@echo "Building e2e orchestrator"
	$(DOCKER) build -t orchestrator -f contrib/localnet/orchestrator/Dockerfile.fastbuild .
.PHONY: orchestrator

install-zetae2e: go.sum
	@echo "--> Installing zetae2e"
	@go install -mod=readonly $(BUILD_FLAGS) ./cmd/zetae2e
.PHONY: install-zetae2e

solana:
	@echo "Building solana docker image"
	$(DOCKER) build -t solana-local -f contrib/localnet/solana/Dockerfile contrib/localnet/solana/

start-e2e-test: e2e-images
	@echo "--> Starting e2e test"
	cd contrib/localnet/ && $(DOCKER_COMPOSE) up -d

start-e2e-admin-test: e2e-images
	@echo "--> Starting e2e admin test"
	export E2E_ARGS="--skip-regular --test-admin" && \
	cd contrib/localnet/ && $(DOCKER_COMPOSE) --profile eth2 up -d

start-e2e-performance-test: e2e-images solana
	@echo "--> Starting e2e performance test"
	export E2E_ARGS="--test-performance" && \
	cd contrib/localnet/ && $(DOCKER_COMPOSE) --profile stress up -d

start-e2e-import-mainnet-test: e2e-images
	@echo "--> Starting e2e import-data test"
	export ZETACORED_IMPORT_GENESIS_DATA=true && \
	export ZETACORED_START_PERIOD=15m && \
	cd contrib/localnet/ && ./scripts/import-data.sh mainnet && $(DOCKER_COMPOSE) up -d

start-e2e-consensus-test: e2e-images
	@echo "--> Starting e2e consensus test"
	export ZETACORE1_IMAGE=ghcr.io/zeta-chain/zetanode:develop && \
	export ZETACORE1_PLATFORM=linux/amd64 && \
	cd contrib/localnet/ && $(DOCKER_COMPOSE) up -d

start-stress-test: e2e-images
	@echo "--> Starting stress test"
	cd contrib/localnet/ && $(DOCKER_COMPOSE) --profile stress up -d

start-tss-migration-test: e2e-images
	@echo "--> Starting tss migration test"
	export LOCALNET_MODE=tss-migrate && \
	export E2E_ARGS="--test-tss-migration" && \
	cd contrib/localnet/ && $(DOCKER_COMPOSE) up -d

start-solana-test: e2e-images solana
	@echo "--> Starting solana test"
	export E2E_ARGS="--skip-regular --test-solana" && \
	cd contrib/localnet/ && $(DOCKER_COMPOSE) --profile solana up -d

start-ton-test: e2e-images
	@echo "--> Starting TON test"
	export E2E_ARGS="--skip-regular --test-ton" && \
	cd contrib/localnet/ && $(DOCKER_COMPOSE) --profile ton up -d

start-sui-test: e2e-images
	@echo "--> Starting sui test"
	export E2E_ARGS="--skip-regular --test-sui" && \
	cd contrib/localnet/ && $(DOCKER_COMPOSE) --profile sui up -d

start-legacy-test: e2e-images
	@echo "--> Starting e2e smart contracts legacy test"
	export E2E_ARGS="--skip-regular --test-legacy" && \
	cd contrib/localnet/ && $(DOCKER_COMPOSE) up -d

###############################################################################
###                         Upgrade Tests              						###
###############################################################################

# build from source only if requested
# NODE_VERSION and NODE_COMMIT must be set as old-runtime depends on lastest-runtime
ifdef UPGRADE_TEST_FROM_SOURCE
zetanode-upgrade: e2e-images
	@echo "Building zetanode-upgrade from source"
	$(DOCKER) build -t zetanode:old -f Dockerfile-localnet --target old-runtime-source \
		--build-arg OLD_VERSION='release/v28' \
		--build-arg NODE_VERSION=$(NODE_VERSION) \
		--build-arg NODE_COMMIT=$(NODE_COMMIT)
		.
.PHONY: zetanode-upgrade
else
zetanode-upgrade: e2e-images
	@echo "Building zetanode-upgrade from binaries"
	$(DOCKER) build -t zetanode:old -f Dockerfile-localnet --target old-runtime \
	--build-arg OLD_VERSION='https://github.com/zeta-chain/node/releases/download/v28.0.0' \
	--build-arg NODE_VERSION=$(NODE_VERSION) \
	--build-arg NODE_COMMIT=$(NODE_COMMIT) \
	.
.PHONY: zetanode-upgrade
endif

start-upgrade-test: zetanode-upgrade
	@echo "--> Starting upgrade test"
	export LOCALNET_MODE=upgrade && \
	export UPGRADE_HEIGHT=225 && \
	cd contrib/localnet/ && $(DOCKER_COMPOSE) --profile upgrade -f docker-compose-upgrade.yml up -d

start-upgrade-test-light: zetanode-upgrade
	@echo "--> Starting light upgrade test (no ZetaChain state populating before upgrade)"
	export LOCALNET_MODE=upgrade && \
	export UPGRADE_HEIGHT=90 && \
	cd contrib/localnet/ && $(DOCKER_COMPOSE) --profile upgrade -f docker-compose-upgrade.yml up -d

start-upgrade-test-admin: zetanode-upgrade
	@echo "--> Starting admin upgrade test"
	export LOCALNET_MODE=upgrade && \
	export UPGRADE_HEIGHT=90 && \
	export E2E_ARGS="--skip-regular --test-admin" && \
	cd contrib/localnet/ && $(DOCKER_COMPOSE) --profile upgrade -f docker-compose-upgrade.yml up -d

start-upgrade-import-mainnet-test: zetanode-upgrade
	@echo "--> Starting import-data upgrade test"
	export LOCALNET_MODE=upgrade && \
	export ZETACORED_IMPORT_GENESIS_DATA=true && \
	export ZETACORED_START_PERIOD=15m && \
	export UPGRADE_HEIGHT=225 && \
	cd contrib/localnet/ && ./scripts/import-data.sh mainnet && $(DOCKER_COMPOSE) --profile upgrade -f docker-compose-upgrade.yml up -d


###############################################################################
###                         Simulation Tests              					###
###############################################################################

BINDIR ?= $(GOPATH)/bin
SIMAPP = ./simulation


# Run sim is a cosmos tool which helps us to run multiple simulations in parallel.
runsim: $(BINDIR)/runsim
$(BINDIR)/runsim:
	@echo 'Installing runsim...'
	@TEMP_DIR=$$(mktemp -d) && \
	cd $$TEMP_DIR && \
	go install github.com/cosmos/tools/cmd/runsim@v1.0.0 && \
	rm -rf $$TEMP_DIR || (echo 'Failed to install runsim' && exit 1)
	@echo 'runsim installed successfully'


# Configuration parameters for simulation tests
# NumBlocks: Number of blocks to simulate
# BlockSize: Number of transactions in a block
# Commit: Whether to commit the block or not
# Period: Invariant check period
# Timeout: Timeout for the simulation test
define run-sim-test
	@echo "Running $(1)"
	@go test -mod=readonly $(SIMAPP) -run $(2) -Enabled=true \
		-NumBlocks=$(3) -BlockSize=$(4) -Commit=true -Period=0 -v -timeout $(5)
endef

test-sim-nondeterminism:
	$(call run-sim-test,"non-determinism test",TestAppStateDeterminism,100,200,30m)

test-sim-fullappsimulation:
	$(call run-sim-test,"TestFullAppSimulation",TestFullAppSimulation,100,200,30m)

test-sim-import-export:
	$(call run-sim-test,"test-import-export",TestAppImportExport,50,100,30m)

test-sim-after-import:
	$(call run-sim-test,"test-sim-after-import",TestAppSimulationAfterImport,100,200,30m)

test-sim-multi-seed-long: runsim
	@echo "Running long multi-seed application simulation."
	@$(BINDIR)/runsim -Jobs=4 -SimAppPkg=$(SIMAPP) -ExitOnFail 500 50 TestFullAppSimulation

test-sim-multi-seed-short: runsim
	@echo "Running short multi-seed application simulation."
	@$(BINDIR)/runsim -Jobs=4 -SimAppPkg=$(SIMAPP) -ExitOnFail 50 10 TestFullAppSimulation

test-sim-import-export-long: runsim
	@echo "Running application import/export simulation. This may take several minutes"
	@$(BINDIR)/runsim -Jobs=4 -SimAppPkg=$(SIMAPP) -ExitOnFail 500 50 TestAppImportExport

test-sim-after-import-long: runsim
	@echo "Running application simulation-after-import. This may take several minute"
	@$(BINDIR)/runsim -Jobs=4 -SimAppPkg=$(SIMAPP) -ExitOnFail 500 50 TestAppSimulationAfterImport

.PHONY: \
test-sim-nondeterminism \
test-sim-fullappsimulation \
test-sim-multi-seed-long \
test-sim-multi-seed-short \
test-sim-import-export \
test-sim-after-import \
test-sim-import-export-long \
test-sim-after-import-long


###############################################################################
###                                GoReleaser  		                        ###
###############################################################################

release-snapshot:
	$(GORELEASER) --clean --skip=validate --skip=publish --snapshot

release-build-only:
	$(GORELEASER) --clean --skip=validate --skip=publish

release:
	@if [ ! -f ".release-env" ]; then \
		echo "\033[91m.release-env is required for release\033[0m";\
		exit 1;\
	fi
	$(GORELEASER) --clean --skip=validate

###############################################################################
###                     Local Mainnet Development                           ###
###############################################################################

#ETHEREUM
start-eth-node-mainnet:
	cd contrib/rpc/ethereum && DOCKER_TAG=$(DOCKER_TAG) docker-compose up

stop-eth-node-mainnet:
	cd contrib/rpc/ethereum && DOCKER_TAG=$(DOCKER_TAG) docker-compose down

clean-eth-node-mainnet:
	cd contrib/rpc/ethereum && DOCKER_TAG=$(DOCKER_TAG) docker-compose down -v

###############################################################################
###                               Debug Tools                               ###
###############################################################################

filter-missed-btc: install-zetatool
	zetatool filterdeposit btc --config ./tool/filter_missed_deposits/zetatool_config.json

filter-missed-eth: install-zetatool
	zetatool filterdeposit eth \
		--config ./tool/filter_missed_deposits/zetatool_config.json \
		--evm-max-range 1000 \
		--evm-start-block 19464041
