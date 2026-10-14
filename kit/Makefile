# Thin wrapper around bin/img. Everything is driven by a profile (profiles/<name>.env).
#   make PROFILE=p1-selfhosted-registry doctor
#   make PROFILE=p1-selfhosted-registry release APP=../myapp NAME=myapp TAG=1.2.3
#   make PROFILE=p1-selfhosted-registry deploy REF=registry.example.internal:5443/team/myapp@sha256:...
PROFILE ?= p1-company-registry
APP     ?= .
NAME    ?= $(notdir $(abspath $(APP)))
TAG     ?= $(shell git -C $(APP) describe --tags --always --dirty 2>/dev/null || date +%Y%m%d%H%M)
IMG      = bin/img -p $(PROFILE)

.PHONY: help render render-all doctor builder keygen build scan release deploy ship-ssh bundle import mirror-tools \
        bundle-tools registry-up registry-down registry-certs validate
help:            ## this list
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-14s %s\n", $$1, $$2}'
render:          ## render build/$(PROFILE)/ from the profile
	$(IMG) render
render-all:      ## render every profile
	bin/render.py --all
doctor:          ## check this machine + the server (SSH) + registry reachability against the profile
	$(IMG) doctor
keygen:          ## cosign key pair (needs COSIGN_PASSWORD)
	$(IMG) keygen
builder:         ## create the buildx builder for BUILDER_MODE (local | remote | multinode)
	$(IMG) builder
build:           ## build (+push / --load / OCI archive, per TRANSPORT)
	$(IMG) build $(APP) $(NAME) $(TAG)
scan:            ## vulnerability gate on REF (registry ref, oci-archive:path)
	$(IMG) scan $(REF)
release:         ## build + push + scan gate + sign + verify (TRANSPORT=registry)
	$(IMG) release $(APP) $(NAME) $(TAG)
deploy:          ## on the server: verify signature, pull SERVER_PLATFORM by digest (REF=...@sha256:...)
	$(IMG) deploy $(REF)
ship-ssh:        ## docker save --platform | zstd | ssh docker load (IMAGE=name:tag)
	$(IMG) ship-ssh $(IMAGE)
bundle:          ## sha256 + cosign sign-blob for an OCI archive (ARCHIVE=dist/x.oci.tar)
	$(IMG) bundle $(ARCHIVE)
import:          ## inside: verify + skopeo copy --all ARCHIVE into REF
	$(IMG) import $(ARCHIVE) $(REF)
mirror-tools:    ## copy cosign/grype/skopeo/regctl into $REGISTRY/tools/* (offline servers)
	$(IMG) mirror-tools
bundle-tools:    ## tool images for SERVER_PLATFORM as one zstd docker-save archive (air-gap bootstrap)
	$(IMG) bundle-tools tools.tar.zst
registry-certs:  ## internal CA + registry cert for the profile's registry (and mirror) host names
	registry/mkcerts.sh build/$(PROFILE)/certs $$(bin/render.py --get $(PROFILE) REGISTRY_HOST) $(EXTRA_SANS)
registry-up:     ## start the self-hosted registry (+ mirror) of the profile
	docker compose --env-file build/$(PROFILE)/registry/.env -f registry/compose.yaml up -d
registry-down:   ## stop it (data volumes kept)
	docker compose --env-file build/$(PROFILE)/registry/.env -f registry/compose.yaml down
validate:        ## render + lint + config-check every profile (no network, no side effects)
	tests/validate.sh
