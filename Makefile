# ensure sh
SHELL := /bin/sh
# clear out suffixes
.SUFFIXES:

# set some vars
SRC := $(filter-out %_test.go,$(wildcard *.go))
TEST_FILES := $(wildcard *_test.go)
PKGS ?= ./...

BINARY ?= Butter

GO ?= go

# export vars
export

.PHONY: all
all: $(BINARY)

$(BINARY): $(SRC)
	$(GO) build -o $(BINARY) $(GOBUILDFLAGS) -v $(PKGS)

.PHONY: install
install:
	$(GO) install $(GOBUILDFLAGS) $(PKGS)

.PHONY: clean
clean:
	-$(GO) clean $(GOCLEANFLAGS) $(PKGS)

.PHONY: clean_uninstall
clean_uninstall: GOCLEANFLAGS += -i
clean_uninstall: clean

.PHONY: fmt
fmt: $(SRC)
	$(GO) fmt $(GOFMTFLAGS) $(PKGS)

.PHONY: vet
vet: $(SRC)
	$(GO) vet $(GOVETFLAGS) $(PKGS)

TEST_TARGETS := test-default test-bench test-short test-verbose test-race
test-bench:   GOTESTFLAGS=-run=__absolutelynothing__ -bench=.
test-short:   GOTESTFLAGS=-short
test-verbose: GOTESTFLAGS=-v
test-race:    GOTESTFLAGS=-race

.PHONY: $(TEST_TARGETS) check test tests
$(TEST_TARGETS) check test tests: $(TEST_FILES)
	$(GO) test $(GOBUILDFLAGS) $(GOTESTFLAGS) $(PKGS)
