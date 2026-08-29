# Issues

Deferred, known, and not yet addressed. One section per issue; delete the
section when it lands.

## compute-version restarts an rc series it should continue

alpine-servo-build's new release came out as `v0.4.0_rc0` although `v0.4.0_rc1`
already existed -- the newer, better artifact sorts *below* the one it replaces
and took the `Latest` marker. Same mechanism (compute-version reading its state
from the version branch) that produced moonshine's two failed releases when
`dev`'s VERSION was stale: state on the version branch and the actually
published tags can disagree, and nothing cross-checks them.

Repo: github-workflows (`compute-version.yml`), bit alpine-servo-build.
Fix direction: have compute-version verify the version it computed does not
already exist as a tag/release -- and if it does, continue the series past it
rather than fail or restart it.

## softpipe vs llvmpipe never measured

Every size number is measured; no performance number is. Softpipe interprets
shaders where llvmpipe JITs them, and both browsers-on-softpipe conclusions
were drawn headless at 600x500. Whether softpipe holds up at panel resolution
on the real device is open, and it decides whether the 15 MiB mesa or the
73 MiB one ships.

Repo: iss-display (consumes both), moonshine (publishes both).
Plan: same image both ways -- `MOONSHINE_SWAY_WEB_VERSION=llvmpipe` +
`VJU_FLAVOUR=vju` vs the softpipe defaults -- then servo page-load/first-paint
and vju frame cadence at real resolution. The pair must switch together: plain
vju on softpipe is the one combination that does not run.

## iss-display keeps a gitignored controller.py that can shadow the packaged one

The overriding `COPY controller.py /usr/local/bin` is gone -- the image now
takes the controller from the iss-display-controller image alone -- but the
gitignored working copy remains, and `./run` bind mounts it over the packaged
one when present. That is visible at run time rather than baked in, which is
the point, but the file itself is still invisible to git and drifts (it has
before, by ~50 lines).

Repo: iss-display.
Fix direction: make the dev override reach for the controller repo's checkout
instead (`../iss-display-controller/controller.py`) or delete the local copy
whenever it matches the packaged one.

## Release order: doi@dev must land before iss-display-controller rebuilds

controller.py calls `System.host_uptime()`/`host_uptime_seconds()` and, via
`ProcessStats`, the extended `System.process_cpu_times()` fields (threads,
starttime) -- all of which exist only in doi's working tree. requirements.txt
installs doi from `git+...@dev`. A controller image built before the doi
change is pushed raises AttributeError on the system view and every /metrics
scrape.

Repos: doi, iss-display-controller.
Fix: push doi's dev first; nothing else needed.

## gst-moonshine impersonates Alpine's gst package names

`provides="gst-plugins-base=1.28.3 ..."` exists so the *released* scream apk,
which depends on those names, resolves to gst-moonshine. The claim is broader
than what is built: a future package genuinely needing the full plugin set
would resolve here and fail at runtime, and the =1.28.3 pins stop satisfying
anything requiring a newer version. scream's APKBUILD now depends on
gst-moonshine directly; once a scream release built that way exists, drop the
provides= lines.

Repos: moonshine (gst-moonshine), scream.

## vju flavour plumbing can collapse after the next vju release

The next vju release ships /usr/bin/vju in both flavours (vju-glow symlinks
it). After iss-display bumps VJU_VERSION: drop `ENV VJU_BIN`, use plain `vju`
in the sway exec line, and let the controller default do the rest --
VJU_FLAVOUR then only selects which apk is fetched.

Repo: iss-display.

## libx11 survives in the base through cairo and pango

vju no longer links or declares x11 (next release), but the sway-web base
still carries libx11: Alpine's cairo links the xlib backend unconditionally
and pango pulls libxft, both of which require libx11 -- traced with
apk info -r libx11 (cairo, libxrender, libxft). A truly X-free image needs
cairo built with -Dxlib=disabled and pango without xft, mesa-softpipe style,
consumed by sway-pixman.

Repo: moonshine.
Fix direction: cairo/pango moonshine packages (or fold into sway-pixman's
static approach); only then can libx11 join iss-display's forbidden list.
