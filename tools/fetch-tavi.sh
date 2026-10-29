#!/bin/sh
# Puts Tavi's latest verified release where the Orbit build embeds it from (tools/tavi-cache).
set -e
cd "$(dirname "$0")/.."
exec /usr/bin/swift tools/fetch-tavi.swift tools/tavi-cache
