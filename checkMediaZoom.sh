#!/usr/bin/env bash
# checkMediaZoom.sh tests MCZbase's enlarged view of media images, /shared/js/media-zoom.js, in headless
# Chromium: placement beside the image, sizing, wheel and +/- zoom, panning and the lens, scrolling,
# Escape, collapsing containers, a large image that fails to load, touch, the keyboard view, and turning
# it off.  It needs no server: it runs a static test page against the script and stylesheet from an
# MCZbase checkout.
#
# Copyright 2026 President and Fellows of Harvard College
# Licensed under the Apache License, Version 2.0; see LICENSE.
#
# Usage: ./checkMediaZoom.sh [-h] /path/to/MCZbase
#
# Needs chromium and node (no packages).  The exit status is the number of failed checks, at most 255.

usage() {
	cat <<USAGE
Usage: $0 [-h] /path/to/MCZbase

Tests /shared/js/media-zoom.js from the given MCZbase checkout in headless Chromium, and prints PASS or
FAIL for each check.  The exit status is the number of failed checks, at most 255.

  -h  show this help.
USAGE
}
if [ "$1" = "-h" ]; then
	usage
	exit 0
fi
MCZBASE="${1%/}"
if [ -z "$MCZBASE" ] || [ ! -f "$MCZBASE/shared/js/media-zoom.js" ]; then
	usage >&2
	exit 255
fi
CHROME=$(command -v chromium || command -v chromium-browser || command -v google-chrome || true)
if [ -z "$CHROME" ] || ! command -v node > /dev/null; then
	echo "Needs chromium and node on the PATH" >&2
	exit 255
fi
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/site/shared/js" "$WORK/site/shared/css" "$WORK/site/shared/images"
cp "$HERE/mediaZoom/index.html" "$HERE/mediaZoom/large.svg" "$WORK/site/"
cp "$MCZBASE/shared/js/media-zoom.js" "$WORK/site/shared/js/"
cp "$MCZBASE/shared/css/media_zoom.css" "$WORK/site/shared/css/"
cp "$MCZBASE/shared/images/indicator.gif" "$WORK/site/shared/images/"
echo "== media-zoom.js from $MCZBASE ($(git -C "$MCZBASE" rev-parse --short=10 HEAD 2>/dev/null || echo "not a git checkout"))"
node "$HERE/mediaZoom/drive.js" "$CHROME" "$WORK/chrome-profile" "file://$WORK/site/index.html"
