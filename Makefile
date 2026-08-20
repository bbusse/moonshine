HASH   := $(shell git rev-parse --short HEAD)
REMOTE ?= gh
RELEASE_BRANCH ?= main

ENGINE      ?= podman
ALPINE_TAG  ?= 3.22
ALPINE_BRANCH ?= v3.22
BASE_IMAGE  ?= moonshine-base:brush
BRUSH_IMAGE ?= moonshine-brush:latest
APK_IMAGE   ?= moonshine-apk:latest
SWAY_IMAGE  ?= moonshine-sway:latest
PLATFORM    ?=

PLATFORM_ARG = $(if $(PLATFORM),--platform $(PLATFORM),)
BRUSH_VERSION ?= 0.4.0
BRUSH_PKGREL  ?= 0
UTILS         ?= none

# The moonshine release sway-pixman was published under (see `make rc`/`make
# release`) and the sway-pixman pkgver/pkgrel it published, from
# sway-pixman/apkbuild/APKBUILD. No default for MOONSHINE_VERSION: there is nothing
# sensible to fall back to before a release exists.
MOONSHINE_VERSION ?=
SWAY_PKGVER   ?= 1.12
SWAY_PKGREL   ?= 0

BRUSH_ARGS   = --build-arg BRUSH_VERSION=$(BRUSH_VERSION) --build-arg BRUSH_PKGREL=$(BRUSH_PKGREL)
BASE_ARGS    = --build-arg ALPINE_TAG=$(ALPINE_TAG) --build-arg ALPINE_BRANCH=$(ALPINE_BRANCH) --build-arg UTILS=$(UTILS) $(BRUSH_ARGS)
BRUSHIMG_ARGS= --build-arg ALPINE_TAG=$(ALPINE_TAG) $(BRUSH_ARGS)
SWAY_ARGS    = --build-arg MOONSHINE_VERSION=$(MOONSHINE_VERSION) --build-arg SWAY_PKGVER=$(SWAY_PKGVER) --build-arg SWAY_PKGREL=$(SWAY_PKGREL)

.PHONY: all base brush apk sway test sizes lock shell brush-shell brush-checksums sway-checksums clean help release release-candidate rc _check-remote _check-branch _check-up-to-date

all: base apk brush sway ## build every image

base: ## build the base rootfs image (brush as /bin/sh, no busybox)
	$(ENGINE) build $(PLATFORM_ARG) $(BASE_ARGS) -f Containerfile.base -t $(BASE_IMAGE) .

apk: ## build the base image with apk on board
	$(ENGINE) build $(PLATFORM_ARG) $(BASE_ARGS) --build-arg WITH_APK=1 \
	  -f Containerfile.base -t $(APK_IMAGE) .

sway: apk ## build the sway image on top of the apk image
	$(ENGINE) build $(PLATFORM_ARG) --build-arg APK_IMAGE=$(APK_IMAGE) $(SWAY_ARGS) \
	  -f Containerfile.sway -t $(SWAY_IMAGE) .

brush: ## build the scratch+brush image (no libc at all)
	$(ENGINE) build $(PLATFORM_ARG) $(BRUSHIMG_ARGS) -f Containerfile.brush -t $(BRUSH_IMAGE) .

test: ## verify the images behave
	ENGINE=$(ENGINE) BASE_IMAGE=$(BASE_IMAGE) BRUSH_IMAGE=$(BRUSH_IMAGE) \
	  APK_IMAGE=$(APK_IMAGE) SWAY_IMAGE=$(SWAY_IMAGE) UTILS=$(UTILS) ./test.sh

sizes: ## report image sizes
	@$(ENGINE) images --format '{{.Repository}}:{{.Tag}}\t{{.Size}}' \
	  | grep -E '$(firstword $(subst :, ,$(BASE_IMAGE)))|$(firstword $(subst :, ,$(BRUSH_IMAGE)))|$(firstword $(subst :, ,$(APK_IMAGE)))|$(firstword $(subst :, ,$(SWAY_IMAGE)))' || true

lock: base ## dump exact package versions from the built base image
	@$(ENGINE) run --rm $(BASE_IMAGE) /bin/sh -c \
	  'while read -r l; do echo "$$l"; done < /etc/moonshine-manifest' > base/packages.lock
	@echo "wrote base/packages.lock ($$(wc -l < base/packages.lock) packages)"

shell: base ## interactive brush in the base image
	$(ENGINE) run --rm -it $(BASE_IMAGE) /bin/sh

sway-run: sway ## start sway headless and report what it brought up
	$(ENGINE) run --rm $(SWAY_IMAGE) /bin/sh /usr/local/bin/sway-smoke

brush-shell: brush ## interactive brush in the libc-free image
	$(ENGINE) run --rm -it $(BRUSH_IMAGE)

brush-checksums: ## re-pin brush apk checksums for BRUSH_VERSION
	./brush/checksums.sh $(BRUSH_VERSION) $(BRUSH_PKGREL)

sway-checksums: ## re-pin sway-pixman apk checksums for MOONSHINE_VERSION/SWAY_PKGVER
	./sway-pixman/checksums.sh $(MOONSHINE_VERSION) $(SWAY_PKGVER) $(SWAY_PKGREL)

clean: ## remove built images
	-$(ENGINE) rmi -f $(BASE_IMAGE) $(BRUSH_IMAGE) $(APK_IMAGE) $(SWAY_IMAGE) 2>/dev/null

_check-remote:
	@git remote get-url $(REMOTE) > /dev/null 2>&1 || \
	    { echo "Error: no remote '$(REMOTE)' — add one with: git remote add $(REMOTE) <url>"; exit 1; }

_check-branch:
	@current="$$(git rev-parse --abbrev-ref HEAD)"; \
	if [ "$$current" != "$(RELEASE_BRANCH)" ]; then \
	    echo "Error: on branch '$$current' — releases must be tagged from '$(RELEASE_BRANCH)'. Checkout $(RELEASE_BRANCH) first."; \
	    exit 1; \
	fi

_check-up-to-date: _check-remote _check-branch
	@git fetch $(REMOTE) $(RELEASE_BRANCH) > /dev/null 2>&1
	@git merge-base --is-ancestor $(REMOTE)/$(RELEASE_BRANCH) HEAD || \
	    { echo "Error: $(RELEASE_BRANCH) has commits you don't have — pull/rebase before tagging a release."; exit 1; }

# Both targets below share one recipe (tag with a prefix, confirm, push); only the tag
# prefix and prompt wording differ, set here as target-specific variables.
release: TAG_PREFIX := release
release: KIND := release
release-candidate rc: TAG_PREFIX := rc
release-candidate rc: KIND := release candidate

release release-candidate rc: _check-up-to-date ## tag HEAD release-<hash>/rc-<hash> and push
	$(eval TAG := $(TAG_PREFIX)-$(HASH))
	git tag -f $(TAG)
	@printf 'Tagged %s as %s\n' "$(HASH)" "$(TAG)"
	@printf 'Push tag to trigger a %s? [y/N] ' "$(KIND)" && read ans && \
	    case "$$ans" in [yY]) git push $(REMOTE) $(TAG) ;; \
	    *) git tag -d $(TAG); echo 'Aborted — tag removed.' ;; esac

help: ## list targets
	@grep -hE '^[a-z][a-z -]*:.*##' $(MAKEFILE_LIST) | sed 's/:.*##/\t/' | expand -t20
