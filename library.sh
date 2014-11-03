#!/usr/bin/env bash

# Cycript - Optimizing JavaScript Compiler/Runtime
# Copyright (C) 2009-2013  Jay Freeman (saurik)

# GNU General Public License, Version 3 {{{
#
# Cycript is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published
# by the Free Software Foundation, either version 3 of the License,
# or (at your option) any later version.
#
# Cycript is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Cycript.  If not, see <http://www.gnu.org/licenses/>.
# }}}

set -e

function arch() {
    local arch=$1
    local host=$2
    local sdk=$3
    local os=$4
    local min=$5
    shift 5

    rm -rf "libjpeg.${arch}"
    rm -rf "libvncserver.${arch}"

    if ! isysroot=$(xcodebuild -sdk "${sdk}" -version Path); then
        return
    fi

    mkdir "libjpeg.${arch}"
    mkdir "libvncserver.${arch}"

    flags=()
    flags+=(-isysroot "${isysroot}")
    flags+=(-m${os}-version-min="${min}")
    flags+=(-O3 -g3)
    flags+=(-fvisibility=hidden)

    if [[ ${arch} == arm* && ${arch} != arm64 ]]; then
        flags+=(-mthumb)
    fi

    cpp="$*"

    function configure() {
        code=$1
        shift
        CC="clang -arch ${arch}" CXX="clang++ -arch ${arch}" CFLAGS="${flags[*]}" CPPFLAGS="${flags[*]} ${cpp}" ../"${code}"/configure --host="${host}" --disable-shared "$@"
    }

    cd "libjpeg.${arch}"
    configure jpeg-9a
    make
    cd ..

    flags+=(-I"${PWD}/jpeg-9a")

    jpeg=${PWD}/libjpeg.${arch}
    flags+=(-I"${jpeg}")

    cd "libvncserver.${arch}"
    configure libvncserver JPEG_LDFLAGS="-L${jpeg}/.libs -ljpeg"
    make
    cd ..
}

arch armv6 arm-apple-darwin10 iphoneos iphoneos 2.0 -mllvm -arm-reserve-r9
arch arm64 aarch64-apple-darwin11 iphoneos iphoneos 2.0
