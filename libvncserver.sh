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

archs=()
function arch() {
    local arch=$1
    local host=$2
    local sdk=$3
    local os=$4
    local min=$5
    shift 5

    rm -rf "libvncserver.${arch}"
    if ! isysroot=$(xcodebuild -sdk "${sdk}" -version Path); then
        return
    fi

    archs+=("${arch}")
    mkdir "libvncserver.${arch}"

    flags=()
    flags+=(-isysroot "${isysroot}")
    flags+=(-m${os}-version-min="${min}")
    flags+=(-O3 -g3)
    flags+=(-fvisibility=hidden)

    if [[ ${arch} == arm* && ${arch} != arm64 ]]; then
        flags+=(-mthumb)
    fi

    cd "libvncserver.${arch}"
    CC="clang -arch ${arch}" CXX="clang++ -arch ${arch}" CFLAGS="${flags[*]}" CPPFLAGS="${flags[*]} $*" ../libvncserver/configure --host="${host}" --disable-shared
    make
    cd ..
}

arch armv6 arm-apple-darwin10 iphoneos iphoneos 2.0 -mllvm -arm-reserve-r9
arch arm64 aarch64-apple-darwin11 iphoneos iphoneos 2.0

libvncserver=()
for arch in "${archs[@]}"; do
    libvncserver+=(libvncserver."${arch}"/.libs/libvncserver.a)
done

lipo -create -output libvncserver.a "${libvncserver[@]}"
