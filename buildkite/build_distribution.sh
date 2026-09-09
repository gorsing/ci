#!/bin/bash

PS4="~> " # needed to avoid accidentally generating collapsed output
set -uexo pipefail

# Builds DMD, DRuntime, Phobos, tools and DUB + creates a "distribution" archive for latter usage.
echo "--- Setting build variables"

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

"$DIR/clone_repositories.sh"

# Run pre-commit checks on dmd repo if .pre-commit-config.yaml exists
if [ -f dmd/.pre-commit-config.yaml ]; then
    echo "--- Running pre-commit checks"
    pip3 install --quiet --break-system-packages pre-commit
    pushd dmd
    export SKIP=no-commit-to-branch
    pre-commit run --all-files
    echo "--- Checking changelog entries"
    check_prefix="$(find changelog -type f -name '*\.dd' -a ! -name 'dmd\.*' -a ! -name 'druntime\.*')"
    if [ ! -z "${check_prefix}" ]; then
        echo 'All changelog entries must begin with either `dmd.` or `druntime.`'
        echo "Found: ${check_prefix}"
        exit 1
    fi
    check_ext="$(find changelog -type f ! -name 'README\.md' -a ! -name '*\.dd')"
    if [ ! -z "${check_ext}" ]; then
        echo 'All changelog entries must end with `.dd`'
        echo "Found: ${check_ext}"
        exit 1
    fi
    popd
    echo "--- Pre-commit checks passed"
fi

echo "--- Building dmd"
if [ -f dmd/src/bootstrap.sh ]; then
    dmd/src/bootstrap.sh

    for dir in druntime phobos ; do
        echo "--- Building $dir"
        make -C $dir -f posix.mak --jobs=4
    done
else
    dmd/compiler/src/bootstrap.sh
    echo "--- Building druntime"
    make -C dmd/druntime/ -f posix.mak -j4
    echo "--- Building Phobos"
    make -C phobos -f posix.mak -j4
fi

echo "--- Building dub"
pushd dub
# enable experimental build cache improvements https://github.com/dlang/dub/pull/1589
sed -i 's|bool m_filterVersions = false;|bool m_filterVersions = true;|' source/dub/commandline.d
DMD="../dmd/generated/linux/release/64/dmd" ./build.sh
popd

echo "--- Building tools"
make -C tools -f posix.mak RELEASE=1 --jobs=4

echo "--- Building distribution"
if [ -d dmd/druntime ]; then
    DRUNTIME_IMPORTS='dmd/druntime/import/*'
else
    DRUNTIME_IMPORTS='druntime/import/*'
fi
mkdir -p distribution/{bin,imports,libs}
cp --archive --link dmd/generated/linux/release/64/dmd dub/bin/dub tools/generated/linux/64/rdmd distribution/bin/
cp --archive --link phobos/etc phobos/std $DRUNTIME_IMPORTS distribution/imports/
cp --archive --link phobos/generated/linux/release/64/libphobos2.{a,so,so*[!o]} distribution/libs/
echo '[Environment]' >> distribution/bin/dmd.conf
echo 'DFLAGS=-I%@P%/../imports -L-L%@P%/../libs -L--export-dynamic -L--export-dynamic -fPIC' >> distribution/bin/dmd.conf

# add buildkite files to the archive
cp -R "$DIR" distribution

XZ_OPT=-0 tar cfJ distribution.tar.xz distribution

# final cleanup
git clean -ffdxq --exclude "distribution.tar.xz" .
