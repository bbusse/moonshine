#!/usr/bin/env bash
#
# SPDX-FileCopyrightText: Björn Busse <bj.rn@baerlin.eu>
# SPDX-License-Identifier: BSD-3-Clause
#
# bash_unit smoke tests for the moonshine images. Run with:
#   bash_unit tests/test_smoke.sh
#
# The images have no busybox, so filesystem assertions cannot be made by
# running tools inside them -- there are no tools. Instead each image is
# exported and inspected from a throwaway Alpine helper, piped over stdin so
# no bind mount (and no podman-machine shared path) is needed. Runtime
# assertions run in the image itself, using brush builtins only.

ENGINE="${ENGINE:-podman}"
BASE_IMAGE="${BASE_IMAGE:-moonshine-base:musl}"
BRUSH_IMAGE="${BRUSH_IMAGE:-moonshine-brush:latest}"
APK_IMAGE="${APK_IMAGE:-moonshine-apk:latest}"
SWAY_IMAGE="${SWAY_IMAGE:-moonshine-sway:latest}"
UTILS="${UTILS:-none}"
HELPER="${HELPER:-docker.io/library/alpine:3.24}"

# Builds every image once, before any test runs, rather than per-test: these
# are real container builds (sway-pixman compiles wlroots+sway from source,
# minutes not milliseconds), and no test below mutates an image, so sharing
# one build across the whole suite is both correct and the only way this
# finishes in reasonable time.
setup_suite() {
    local root
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    local targets="base apk brush"

    # The sway image installs sway-pixman from a moonshine release, so it can
    # only be built once one exists. Without MOONSHINE_VERSION, skip building
    # it -- the Makefile skips its tests to match.
    if [ -n "${MOONSHINE_VERSION:-}" ]; then
        targets="$targets sway"
    fi

    # shellcheck disable=SC2086
    make -C "$root" $targets \
        ENGINE="$ENGINE" BASE_IMAGE="$BASE_IMAGE" APK_IMAGE="$APK_IMAGE" \
        BRUSH_IMAGE="$BRUSH_IMAGE" SWAY_IMAGE="$SWAY_IMAGE" UTILS="$UTILS" \
        MOONSHINE_VERSION="${MOONSHINE_VERSION:-}"
}

# Unpack an image's filesystem into /r in a helper container and run a script
# against it. $1 = image, $2 = sh script evaluated with cwd at the root.
fs() {
    local image="$1" script="$2" cid rc=0
    cid="$($ENGINE create --quiet "$image" 2>/dev/null)"
    $ENGINE export "$cid" 2>/dev/null \
        | $ENGINE run --rm -i "$HELPER" sh -c \
            "mkdir -p /r && tar -C /r -xf - >/dev/null 2>&1; cd /r && { $script ; }" \
        || rc=$?
    $ENGINE rm -f "$cid" >/dev/null 2>&1 || true
    return $rc
}
base_fs()  { fs "$BASE_IMAGE" "$1"; }
brush_fs() { fs "$BRUSH_IMAGE" "$1"; }
apk_fs()   { fs "$APK_IMAGE" "$1"; }
sway_fs()  { fs "$SWAY_IMAGE" "$1"; }
run_in()   { $ENGINE run --rm "$@"; }

test_musl_loader_present() {
    base_fs 'ls lib/ld-musl-*.so.1' || fail "musl loader not present"
}
test_libc_symlink_resolves() {
    base_fs 'test -L lib/libc.musl-*.so.1' || fail "libc symlink does not resolve"
}
test_bin_sh_is_brush() {
    base_fs 'test "$(readlink bin/sh)" = /usr/bin/brush' || fail "/bin/sh is not brush"
}
test_no_busybox_binary() {
    base_fs '! find . -name "busybox*" -print | grep -q .' || fail "found a busybox binary"
}
test_no_busybox_in_apk_db() {
    base_fs '! grep -q "^P:busybox" lib/apk/db/installed' || fail "busybox is in the apk db"
}
test_brush_in_apk_db() {
    base_fs 'grep -q "^P:brush$" lib/apk/db/installed' || fail "brush is not in the apk db"
}
# /bin/sh must be package-owned, not a bare symlink: apk resolves /bin/sh
# against metadata, so an unowned link lets anything needing a shell drag
# busybox-binsh back in and take it over.
test_brush_binsh_in_apk_db() {
    base_fs 'grep -q "^P:brush-binsh$" lib/apk/db/installed' || fail "brush-binsh is not in the apk db"
}
test_brush_binsh_provides_sh() {
    base_fs 'grep -q "^p:/bin/sh" lib/apk/db/installed' || fail "brush-binsh does not provide /bin/sh"
}
test_bin_sh_has_priority_100() {
    base_fs 'grep -q "^k:100$" lib/apk/db/installed' || fail "/bin/sh provider priority is not 100"
}
# UTILS=uutils puts coreutils in /bin too, so assert on shells, not on /bin
test_no_other_shell_binaries() {
    base_fs '! find . \( -name ash -o -name bash -o -name dash -o -name "busybox*" -o -name "ksh*" -o -name zsh \) -print | grep -q .' \
        || fail "found a shell binary other than brush"
}
test_etc_shells_has_no_ash() {
    base_fs '! grep -q ash etc/shells' || fail "/etc/shells still lists ash"
}
test_root_login_shell_is_brush() {
    base_fs 'grep -q "^root:.*:/usr/bin/brush$" etc/passwd' || fail "root's login shell is not brush"
}
test_baselayout_data_etc_group() {
    base_fs 'grep -q "^wheel:" etc/group' || fail "/etc/group is missing the wheel group"
}
test_ca_bundle_present() {
    base_fs 'test -s etc/ssl/certs/ca-certificates.crt' || fail "CA bundle missing or empty"
}
test_tzdata_present() {
    base_fs 'test -e usr/share/zoneinfo/UTC' || fail "tzdata missing"
}
test_tmp_is_1777() {
    base_fs 'test "$(stat -c %a tmp)" = 1777' || fail "/tmp is not mode 1777"
}
test_var_tmp_is_1777() {
    base_fs 'test "$(stat -c %a var/tmp)" = 1777' || fail "/var/tmp is not mode 1777"
}
test_var_run_symlinks_to_run() {
    base_fs 'test "$(readlink var/run)" = /run' || fail "/var/run does not symlink to /run"
}
# baselayout-data ships this relative; layout.sh writes it absolute if absent
test_etc_mtab_symlinks_to_proc_mounts() {
    base_fs 'case "$(readlink etc/mtab)" in /proc/mounts|../proc/mounts) ;; *) exit 1 ;; esac' \
        || fail "/etc/mtab does not symlink to proc/mounts"
}
test_no_package_cache_left() {
    base_fs '! ls var/cache/apk/* 2>/dev/null | grep -q .' || fail "apk cache left behind"
}
test_manifest_recorded() {
    base_fs 'test -s etc/moonshine-manifest' || fail "moonshine-manifest missing or empty"
}
test_release_key_kept() {
    base_fs 'test -s etc/apk/keys/apk-releases.rsa.pub' || fail "release signing key missing"
}

# Runtime: brush builtins only -- no external command exists to lean on.
test_bin_sh_runs() {
    run_in "$BASE_IMAGE" /bin/sh -c 'exit 0' || fail "/bin/sh did not run"
}
# brushinfo is a brush-only builtin, so `type` finding it identifies the shell
test_bin_sh_really_is_brush() {
    run_in "$BASE_IMAGE" /bin/sh -c 'type brushinfo' || fail "/bin/sh is not really brush"
}
test_test_builtin_works() {
    run_in "$BASE_IMAGE" /bin/sh -c '[ -d / ] || exit 1' || fail "test builtin did not work"
}
test_glob_and_printf_work() {
    $ENGINE run --rm "$BASE_IMAGE" /bin/sh -c 'printf "%s\n" /bin/*' | grep -q /bin/brush \
        || fail "glob/printf did not expand /bin/*"
}
test_no_external_commands_by_default() {
    [ "$UTILS" = none ] || return 0
    $ENGINE run --rm "$BASE_IMAGE" /bin/sh -c 'ls /' >/dev/null 2>&1 \
        && fail "expected no external commands, but ls succeeded"
    return 0
}
test_uutils_ls_works() {
    [ "$UTILS" != none ] || return 0
    run_in "$BASE_IMAGE" /bin/sh -c 'ls / >/dev/null' || fail "uutils ls did not work"
}

test_apk_binary_present() {
    apk_fs 'test -x sbin/apk' || fail "apk binary missing"
}
test_apk_tools_in_db() {
    apk_fs 'grep -q "^P:apk-tools" lib/apk/db/installed' || fail "apk-tools not in the apk db"
}
test_repositories_configured() {
    apk_fs 'test "$(grep -c dl-cdn etc/apk/repositories)" = 2' || fail "apk repositories not configured"
}
test_alpine_signing_keys_present() {
    # Count, not a specific number: Alpine prunes retired keys between
    # releases (3.22 shipped 5, 3.24 ships 2), so anything higher than 1 is an
    # assertion about Alpine's key rotation rather than about this image.
    # That apk can actually verify a signature is covered by
    # test_apk_installs_a_package.
    apk_fs 'test "$(ls etc/apk/keys | grep -c alpine-devel)" -ge 1' || fail "alpine signing keys missing"
}
test_apk_runs() {
    run_in "$APK_IMAGE" /sbin/apk --version || fail "apk did not run"
}
test_apk_installs_a_package() {
    run_in "$APK_IMAGE" /bin/sh -c 'apk add --no-cache libgcc' || fail "apk failed to install a package"
}
# The regression this guards: before brush-binsh existed, this pulled in
# busybox and busybox-binsh and left /bin/sh pointing at busybox.
test_install_keeps_brush_as_sh() {
    $ENGINE run --rm "$APK_IMAGE" /bin/sh -c 'apk add --no-cache ca-certificates' 2>&1 | grep -q busybox \
        && fail "installing a package pulled in busybox"
    return 0
}

test_sway_installed() {
    sway_fs 'test -x usr/bin/sway' || fail "sway binary missing"
}
# The point of building our own: Alpine's sway drags mesa + llvm20-libs in
# through wlroots' GLES/Vulkan renderers, 245 MB that never renders anything
# under WLR_RENDERER=pixman.
test_sway_no_mesa_llvm_vulkan_pkgs() {
    sway_fs '! grep "^P:" lib/apk/db/installed | grep -qiE "mesa|llvm|vulkan|spirv"' \
        || fail "found a mesa/llvm/vulkan package"
}
test_sway_no_libegl_libgallium_files() {
    sway_fs '! find . \( -name "libEGL*" -o -name "libgallium*" -o -name "libLLVM*" -o -name "libgbm*" \) | grep -q .' \
        || fail "found a libEGL/libgallium/libLLVM/libgbm file"
}
test_sway_wlroots_is_linked_static() {
    sway_fs '! find . -name "libwlroots*" | grep -q .' || fail "found a dynamic libwlroots"
}
test_sway_pixman_is_our_package() {
    sway_fs 'grep -q "^P:sway-pixman$" lib/apk/db/installed' || fail "sway-pixman not in the apk db"
}
test_sway_image_still_no_busybox() {
    sway_fs '! find . -name "busybox*" -print | grep -q .' || fail "found a busybox binary in the sway image"
}
test_sway_image_brush_is_still_bin_sh() {
    sway_fs 'test "$(readlink bin/sh)" = /usr/bin/brush' || fail "/bin/sh is not brush in the sway image"
}
test_sway_config_installed() {
    sway_fs 'grep -q "moonshine sway" etc/sway/config' || fail "moonshine sway config not installed"
}
test_sway_coreutils_available() {
    run_in "$SWAY_IMAGE" /bin/sh -c 'ls / >/dev/null' || fail "coreutils not available in the sway image"
}
# Alpine ships sway with cap_sys_nice=ep, and a file capability outside the
# container's bounding set makes execve fail with EPERM. The build strips it,
# so this must work with no --cap-add at all.
test_sway_runs_without_extra_caps() {
    run_in "$SWAY_IMAGE" /usr/bin/sway --version || fail "sway did not run without extra capabilities"
}
test_sway_comes_up_headless() {
    $ENGINE run --rm "$SWAY_IMAGE" /bin/sh /usr/local/bin/sway-smoke | grep -q '"width": 1280' \
        || fail "sway did not come up headless at the expected size"
}

test_brush_runs_with_no_libc() {
    $ENGINE run --rm "$BRUSH_IMAGE" -c 'echo ok' | grep -q ok || fail "brush did not run with no libc"
}
test_brush_image_has_no_libc() {
    brush_fs '! ls lib/ld-musl-* 2>/dev/null | grep -q .' || fail "brush image still has a libc"
}
test_brush_image_is_brush_and_tmp_only() {
    brush_fs 'test "$(find . -type f | wc -l)" = 1' || fail "brush image has more than just the brush binary"
}
