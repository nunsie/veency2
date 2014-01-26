#!/bin/bash
git describe --always --tags --dirty="+" --match="v[0-9]*" | sed -e 's@-\([^-]*\)-\([^-]*\)$@+\1.\2@;s@^v@@'
