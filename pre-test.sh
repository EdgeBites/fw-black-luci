#!/bin/sh
# pre-test.sh - dependencies for the CI runtime test that are not part of
# the package itself (runs before the package is installed).
apk add nftables
