# SPDX-FileCopyrightText: Björn Busse <bj.rn@baerlin.eu>
# SPDX-License-Identifier: BSD-3-Clause

HASH   := $(shell git rev-parse --short HEAD)
REMOTE ?= gh
RELEASE_BRANCH ?= ci

ENGINE      ?= podman
ALPINE_TAG  ?= 3.24
ALPINE_BRANCH ?= v3.24
BASE_IMAGE  ?= moonshine-base:brush
BRUSH_IMAGE ?= moonshine-brush:latest
APK_IMAGE   ?= moonshine-apk:latest
PYTHON_IMAGE ?= moonshine-python:latest
SWAY_IMAGE  ?= moonshine-sway:latest
SWAY_WEB_IMAGE ?= moonshine-sway-web:latest
CATALYST_IMAGE ?= moonshine-catalyst:local
STAGE3_IMAGE ?= moonshine-stage3:local
PLATFORM    ?=

STAGE1   ?=
SUBARCH  ?= amd64
VARIANT  ?= openrc
# Empty: Containerfile.stage3 derives default/linux/$(SUBARCH)/23.0.
# Set it for a non-default profile (hardened, musl, llvm).
PROFILE  ?=
JOBS     ?= 4

PLATFORM_ARG = $(if $(PLATFORM),--platform $(PLATFORM),)
BRUSH_VERSION ?= 0.4.0
BRUSH_PKGREL  ?= 0
UTILS         ?= none

# The moonshine release sway-pixman was published under (see `make rc`/`make
# release`) and the sway-pixman pkgver/pkgrel it published, from
# sway-pixman/apkbuild/APKBUILD. No default for MOONSHINE_VERSION: there is nothing
# sensible to fall back to before a release exists.
MOONSHINE_VERSION ?= v0-rc3

SWAY_PKGVER   ?= 1.12
SWAY_PKGREL   ?= 0

# uutils, from uutils/apkbuild/APKBUILD. Which utilities it contains is
# set by _utils in that file, not here.
UUTILS_PKGVER ?= 0.10.0
UUTILS_PKGREL ?= 4

RELEASE_URL   ?= https://github.com/bbusse/moonshine/releases/download

BRUSH_ARGS   = --build-arg BRUSH_VERSION=$(BRUSH_VERSION) --build-arg BRUSH_PKGREL=$(BRUSH_PKGREL)
UUTILS_ARGS  = --build-arg MOONSHINE_VERSION=$(MOONSHINE_VERSION) --build-arg UUTILS_PKGVER=$(UUTILS_PKGVER) --build-arg UUTILS_PKGREL=$(UUTILS_PKGREL)
BASE_ARGS    = --build-arg ALPINE_TAG=$(ALPINE_TAG) --build-arg ALPINE_BRANCH=$(ALPINE_BRANCH) --build-arg UTILS=$(UTILS) $(BRUSH_ARGS) $(UUTILS_ARGS)
BRUSHIMG_ARGS= --build-arg ALPINE_TAG=$(ALPINE_TAG) $(BRUSH_ARGS)
PYTHON_ARGS  = --build-arg ALPINE_TAG=$(ALPINE_TAG) $(UUTILS_ARGS)
SWAY_ARGS    = --build-arg MOONSHINE_VERSION=$(MOONSHINE_VERSION) --build-arg SWAY_PKGVER=$(SWAY_PKGVER) --build-arg SWAY_PKGREL=$(SWAY_PKGREL) --build-arg UUTILS_PKGVER=$(UUTILS_PKGVER) --build-arg UUTILS_PKGREL=$(UUTILS_PKGREL)

.PHONY: all base brush apk python sway sway-web catalyst stage3 test sizes lock shell brush-shell brush-checksums sway-checksums uutils-checksums clean help release release-candidate rc _check-remote _check-branch _check-up-to-date

all: base apk brush python sway sway-web ## build every image

base: ## build the base rootfs image (brush as /bin/sh, no busybox)
	$(ENGINE) build $(PLATFORM_ARG) $(BASE_ARGS) -f Containerfile.base -t $(BASE_IMAGE) .

apk: ## build the base image with apk on board
	$(ENGINE) build $(PLATFORM_ARG) $(BASE_ARGS) --build-arg WITH_APK=1 \
	  -f Containerfile.base -t $(APK_IMAGE) .

python: apk ## build the python image on top of the apk image
	$(ENGINE) build $(PLATFORM_ARG) --build-arg APK_IMAGE=$(APK_IMAGE) $(PYTHON_ARGS) \
	  -f Containerfile.python -t $(PYTHON_IMAGE) .

sway: apk ## build the sway image on top of the apk image
	$(ENGINE) build $(PLATFORM_ARG) --build-arg APK_IMAGE=$(APK_IMAGE) $(SWAY_ARGS) \
	  -f Containerfile.sway -t $(SWAY_IMAGE) .

sway-web: sway ## build the sway image with Firefox and geckodriver
	$(ENGINE) build $(PLATFORM_ARG) --build-arg SWAY_IMAGE=$(SWAY_IMAGE) \
	  --build-arg ALPINE_TAG=$(ALPINE_TAG) \
	  -f Containerfile.sway-web -t $(SWAY_WEB_IMAGE) .

catalyst: ## build the Catalyst builder image (seed + catalyst + portage snapshot)
	$(ENGINE) build $(PLATFORM_ARG) \
	  --build-arg STAGE1=$(STAGE1) \
	  --build-arg SUBARCH=$(SUBARCH) \
	  --build-arg VARIANT=$(VARIANT) \
	  --build-arg JOBS=$(JOBS) \
	  -f Containerfile.catalyst -t $(CATALYST_IMAGE) .

stage3: catalyst ## build a Gentoo stage3 with the Catalyst image (hours, not minutes)
	@printf 'catalyst -f runs emerge --emptytree @system. Expect hours.\n'
	$(ENGINE) build $(PLATFORM_ARG) --cap-add SYS_ADMIN --cap-add SYS_CHROOT \
	  --build-arg CATALYST_IMAGE=$(CATALYST_IMAGE) \
	  --build-arg SUBARCH=$(SUBARCH) \
	  --build-arg PROFILE=$(PROFILE) \
	  --build-arg JOBS=$(JOBS) \
	  -f Containerfile.stage3 -t $(STAGE3_IMAGE) .

brush: ## build the scratch+brush image (no libc at all)
	$(ENGINE) build $(PLATFORM_ARG) $(BRUSHIMG_ARGS) -f Containerfile.brush -t $(BRUSH_IMAGE) .

test: ## verify the images behave (builds them first if needed)
	ENGINE=$(ENGINE) BASE_IMAGE=$(BASE_IMAGE) BRUSH_IMAGE=$(BRUSH_IMAGE) \
	  APK_IMAGE=$(APK_IMAGE) SWAY_IMAGE=$(SWAY_IMAGE) UTILS=$(UTILS) \
	  STAGE3_IMAGE=$(STAGE3_IMAGE) MOONSHINE_VERSION=$(MOONSHINE_VERSION) \
	  bash_unit tests/tests.sh

sizes: ## report image sizes
	@$(ENGINE) images --format '{{.Repository}}:{{.Tag}}\t{{.Size}}' \
	  | grep -E '$(firstword $(subst :, ,$(BASE_IMAGE)))|$(firstword $(subst :, ,$(BRUSH_IMAGE)))|$(firstword $(subst :, ,$(APK_IMAGE)))|$(firstword $(subst :, ,$(PYTHON_IMAGE)))|$(firstword $(subst :, ,$(SWAY_IMAGE)))' || true

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

# $(call sums,<url base>,<asset>...) -- print sha256 lines for the SUMS
# heredocs in the Containerfiles. Downloads to a file and checks curl before
# hashing: piping curl straight into a digest prints the hash of empty input on
# a 404 (e3b0c442...), which looks exactly like a valid pin. openssl rather
# than sha256sum because stock macOS has no sha256sum.
define sums
@t=$$(mktemp -d); trap 'rm -rf "$$t"' EXIT; \
for a in $(2); do \
    curl -fsSL -o "$$t/$$a" "$(1)/$$a" \
      || { echo "could not fetch $(1)/$$a" >&2; exit 1; }; \
    printf '%s  %s\n' "$$(openssl dgst -sha256 -r "$$t/$$a" | cut -d' ' -f1)" "$$a"; \
done
endef

brush-checksums: ## re-pin brush apk checksums for BRUSH_VERSION
	$(call sums,https://github.com/bbusse/alpine-brush-build/releases/download/v$(BRUSH_VERSION),\
	  aarch64-brush-$(BRUSH_VERSION)-r$(BRUSH_PKGREL).apk \
	  x86_64-brush-$(BRUSH_VERSION)-r$(BRUSH_PKGREL).apk)

sway-checksums: ## re-pin sway-pixman apk checksums for MOONSHINE_VERSION/SWAY_PKGVER
	$(call sums,$(RELEASE_URL)/$(MOONSHINE_VERSION),\
	  sway-pixman-$(SWAY_PKGVER)-r$(SWAY_PKGREL).aarch64-$(MOONSHINE_VERSION).apk \
	  sway-pixman-$(SWAY_PKGVER)-r$(SWAY_PKGREL).x86_64-$(MOONSHINE_VERSION).apk)

uutils-checksums: ## re-pin uutils apk checksums for MOONSHINE_VERSION/UUTILS_PKGVER
	$(call sums,$(RELEASE_URL)/$(MOONSHINE_VERSION),\
	  uutils-$(UUTILS_PKGVER)-r$(UUTILS_PKGREL).aarch64-$(MOONSHINE_VERSION).apk \
	  uutils-$(UUTILS_PKGVER)-r$(UUTILS_PKGREL).x86_64-$(MOONSHINE_VERSION).apk)

clean: ## remove built images
	-$(ENGINE) rmi -f $(BASE_IMAGE) $(BRUSH_IMAGE) $(APK_IMAGE) $(PYTHON_IMAGE) $(SWAY_IMAGE) $(SWAY_WEB_IMAGE) $(STAGE3_IMAGE) 2>/dev/null

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
	@grep -hE '^[a-z][a-z0-9 -]*:.*##' $(MAKEFILE_LIST) | sed 's/:.*##/\t/' | expand -t20
