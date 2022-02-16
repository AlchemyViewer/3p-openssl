#!/usr/bin/env bash

shopt -s globstar

cd "$(dirname "$0")"

# turn on verbose debugging output for parabuild logs.
exec 4>&1; export BASH_XTRACEFD=4; set -x
# make errors fatal
set -e
# complain about unreferenced environment variables
set -u

if [ -z "$AUTOBUILD" ] ; then
    exit 1
fi

if [ "$OSTYPE" = "cygwin" ] ; then
    autobuild="$(cygpath -u $AUTOBUILD)"
else
    autobuild="$AUTOBUILD"
fi

# Restore all .sos
restore_sos ()
{
    for solib in "${stage}"/packages/lib/{debug,release}/*.so*.disable; do
        if [ -f "$solib" ]; then
            mv -f "$solib" "${solib%.disable}"
        fi
    done
}


# Restore all .dylibs
restore_dylibs ()
{
    for dylib in "$stage/packages/lib"/{debug,release}/*.dylib.disable; do
        if [ -f "$dylib" ]; then
            mv "$dylib" "${dylib%.disable}"
        fi
    done
}

top="$(pwd)"
stage="$top/stage"

[ -f "$stage"/packages/include/zlib/zlib.h ] || \
{ echo "You haven't yet run 'autobuild install'." 1>&2; exit 1; }

# load autobuild provided shell functions and variables
source_environment_tempfile="$stage/source_environment.sh"
"$autobuild" source_environment > "$source_environment_tempfile"
. "$source_environment_tempfile"

OPENSSL_SOURCE_DIR="openssl"

pushd "$OPENSSL_SOURCE_DIR"
    case "$AUTOBUILD_PLATFORM" in

        windows*)
            load_vsvars

            # We've observed some weird failures in which the PATH is too big
            # to be passed into cmd.exe! When that gets munged, we start
            # seeing errors like failing to understand the 'perl' command --
            # which we *just* successfully used. Thing is, by this point in
            # the script we've acquired a shocking number of duplicate
            # entries. Dedup the PATH using Python's OrderedDict, which
            # preserves the order in which you insert keys.
            # We find that some of the Visual Studio PATH entries appear both
            # with and without a trailing slash, which is pointless. Strip
            # those off and dedup what's left.
            # Pass the existing PATH as an explicit argument rather than
            # reading it from the environment to bypass the fact that cygwin
            # implicitly converts PATH to Windows form when running a native
            # executable. Since we're setting bash's PATH, leave everything in
            # cygwin form. That means splitting and rejoining on ':' rather
            # than on os.pathsep, which on Windows is ';'.
            # Use python -u, else the resulting PATH will end with a spurious '\r'.
            export PATH="$(python -u -c "import sys
from collections import OrderedDict
print(':'.join(OrderedDict((dir.rstrip('/'), 1) for dir in sys.argv[1].split(':'))))" "$PATH")"

            mkdir -p "$stage/lib/debug"
            mkdir -p "$stage/lib/release"

            if [ "$AUTOBUILD_ADDRSIZE" = 32 ]
            then
                debugtargetname=debug-VC-WIN32
                releasetargetname=VC-WIN32
            else
                debugtargetname=debug-VC-WIN64A
                releasetargetname=VC-WIN64A
            fi

            # Debug Build
            perl Configure "$debugtargetname" zlib threads no-shared -DUNICODE -D_UNICODE \
                --with-rand-seed="os,rdcpu" \
                --with-zlib-include="$(cygpath -w "$stage/packages/include/zlib")" \
                --with-zlib-lib="$(cygpath -w "$stage/packages/lib/debug/zlibd.lib")"

            nmake

            # conditionally run unit tests
            if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                nmake test
            fi

            cp -a {libcrypto,libssl}.lib "$stage/lib/debug"

            # Clean
            nmake distclean

            # Release Build
            perl Configure "$releasetargetname" zlib threads no-shared -DUNICODE -D_UNICODE \
                --with-rand-seed="os,rdcpu" \
                --with-zlib-include="$(cygpath -w "$stage/packages/include/zlib")" \
                --with-zlib-lib="$(cygpath -w "$stage/packages/lib/release/zlib.lib")"

            nmake

            # conditionally run unit tests
            if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                nmake test
            fi

            cp -a {libcrypto,libssl}.lib "$stage/lib/release"

            # Publish headers
            mkdir -p "$stage/include/openssl"
            cp -a include/openssl/*.h "$stage/include/openssl"

            # Clean
            nmake distclean
        ;;

        darwin*)
            # Setup osx sdk platform
            SDKNAME="macosx"
            export SDKROOT=$(xcodebuild -version -sdk ${SDKNAME} Path)

            # Deploy Targets
            X86_DEPLOY=10.15
            ARM64_DEPLOY=11.0

            # Setup build flags
            ARCH_FLAGS_X86="-arch x86_64 -mmacosx-version-min=${X86_DEPLOY} -isysroot ${SDKROOT} -msse4.2"
            ARCH_FLAGS_ARM64="-arch arm64 -mmacosx-version-min=${ARM64_DEPLOY} -isysroot ${SDKROOT}"
            DEBUG_COMMON_FLAGS="-O0 -g -fPIC -DPIC"
            RELEASE_COMMON_FLAGS="-O3 -g -fPIC -DPIC -fstack-protector-strong"
            DEBUG_CFLAGS="$DEBUG_COMMON_FLAGS"
            RELEASE_CFLAGS="$RELEASE_COMMON_FLAGS"
            DEBUG_CXXFLAGS="$DEBUG_COMMON_FLAGS -std=c++17"
            RELEASE_CXXFLAGS="$RELEASE_COMMON_FLAGS -std=c++17"
            DEBUG_CPPFLAGS="-DPIC"
            RELEASE_CPPFLAGS="-DPIC"
            DEBUG_LDFLAGS="-Wl,-headerpad_max_install_names"
            RELEASE_LDFLAGS="-Wl,-headerpad_max_install_names"

            # Force static linkage by moving .dylibs out of the way
            trap restore_dylibs EXIT
            for dylib in "$stage/packages/lib"/{debug,release}/*.dylib; do
                if [ -f "$dylib" ]; then
                    mv "$dylib" "$dylib".disable
                fi
            done

            # x86 Deploy Target
            export MACOSX_DEPLOYMENT_TARGET=${X86_DEPLOY}

            # Debug
            mkdir -p "build_x86_debug"
            pushd "build_x86_debug"
                export CFLAGS="$ARCH_FLAGS_X86 $DEBUG_CFLAGS"
                export CXXLAGS="$ARCH_FLAGS_X86 $DEBUG_CXXFLAGS"
                export CPPLAGS="$DEBUG_CPPFLAGS"
                export LDFLAGS="$ARCH_FLAGS_X86 $DEBUG_LDFLAGS"
                ../Configure zlib no-zlib-dynamic threads no-shared debug-darwin64-x86_64-cc "$ARCH_FLAGS_X86 $DEBUG_CFLAGS" \
                    --with-rand-seed="os" \
                    --prefix="$stage/debug_x86" --openssldir="share" \
                    --with-zlib-include="$stage/packages/include/zlib" \
                    --with-zlib-lib="$stage/packages/lib/debug"
                make -j$AUTOBUILD_CPU_COUNT
                # Avoid plain 'make install' because, at least on Yosemite,
                # installing the man pages into the staging area creates problems
                # due to the number of symlinks. Thanks to Cinder for suggesting
                # this make target.
                make install_sw

                # conditionally run unit tests
                if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                    make test
                fi
            popd

            # Release
            mkdir -p "build_x86_release"
            pushd "build_x86_release"
                export CFLAGS="$ARCH_FLAGS_X86 $RELEASE_CFLAGS"
                export CXXLAGS="$ARCH_FLAGS_X86 $RELEASE_CXXFLAGS"
                export CPPLAGS="$RELEASE_CPPFLAGS"
                export LDFLAGS="$ARCH_FLAGS_X86 $RELEASE_LDFLAGS"
                ../Configure zlib no-zlib-dynamic threads no-shared darwin64-x86_64-cc "$ARCH_FLAGS_X86 $RELEASE_CFLAGS" \
                    --with-rand-seed="os" \
                    --prefix="$stage/release_x86" --openssldir="share" \
                    --with-zlib-include="$stage/packages/include/zlib" \
                    --with-zlib-lib="$stage/packages/lib/release"
                make -j$AUTOBUILD_CPU_COUNT
                # Avoid plain 'make install' because, at least on Yosemite,
                # installing the man pages into the staging area creates problems
                # due to the number of symlinks. Thanks to Cinder for suggesting
                # this make target.
                make install_sw

                # conditionally run unit tests
                if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                    make test
                fi
            popd

            # ARM64 Deploy Target
            export MACOSX_DEPLOYMENT_TARGET=${ARM64_DEPLOY}

            # Debug
            mkdir -p "build_arm64_debug"
            pushd "build_arm64_debug"
                export CFLAGS="$ARCH_FLAGS_ARM64 $DEBUG_CFLAGS"
                export CXXLAGS="$ARCH_FLAGS_ARM64 $DEBUG_CXXFLAGS"
                export CPPLAGS="$DEBUG_CPPFLAGS"
                export LDFLAGS="$ARCH_FLAGS_ARM64 $DEBUG_LDFLAGS"
                ../Configure zlib no-zlib-dynamic threads no-shared debug-darwin64-arm64-cc "$ARCH_FLAGS_ARM64 $DEBUG_CFLAGS" \
                    --with-rand-seed="os" \
                    --prefix="$stage/debug_arm64" --openssldir="share" \
                    --with-zlib-include="$stage/packages/include/zlib" \
                    --with-zlib-lib="$stage/packages/lib/debug"
                make -j$AUTOBUILD_CPU_COUNT
                # Avoid plain 'make install' because, at least on Yosemite,
                # installing the man pages into the staging area creates problems
                # due to the number of symlinks. Thanks to Cinder for suggesting
                # this make target.
                make install_sw

                # conditionally run unit tests
                if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                    make test
                fi
            popd

            # Release
            mkdir -p "build_arm64_release"
            pushd "build_arm64_release"
                export CFLAGS="$ARCH_FLAGS_ARM64 $RELEASE_CFLAGS"
                export CXXLAGS="$ARCH_FLAGS_ARM64 $RELEASE_CXXFLAGS"
                export CPPLAGS="$RELEASE_CPPFLAGS"
                export LDFLAGS="$ARCH_FLAGS_ARM64 $RELEASE_LDFLAGS"
                ../Configure zlib no-zlib-dynamic threads no-shared darwin64-arm64-cc "$ARCH_FLAGS_ARM64 $RELEASE_CFLAGS" \
                    --with-rand-seed="os" \
                    --prefix="$stage/release_arm64" --openssldir="share" \
                    --with-zlib-include="$stage/packages/include/zlib" \
                    --with-zlib-lib="$stage/packages/lib/release"
                make -j$AUTOBUILD_CPU_COUNT
                # Avoid plain 'make install' because, at least on Yosemite,
                # installing the man pages into the staging area creates problems
                # due to the number of symlinks. Thanks to Cinder for suggesting
                # this make target.
                make install_sw

                # conditionally run unit tests
                if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                    make test
                fi
            popd

            # create stage structure
            mkdir -p "$stage/include/openssl"
            mkdir -p "$stage/lib/debug"
            mkdir -p "$stage/lib/release"

           # create fat libraries
            lipo -create ${stage}/debug_x86/lib/libcrypto.a ${stage}/debug_arm64/lib/libcrypto.a -output ${stage}/lib/debug/libcrypto.a
            lipo -create ${stage}/debug_x86/lib/libssl.a ${stage}/debug_arm64/lib/libssl.a -output ${stage}/lib/debug/libssl.a
            lipo -create ${stage}/release_x86/lib/libcrypto.a ${stage}/release_arm64/lib/libcrypto.a -output ${stage}/lib/release/libcrypto.a
            lipo -create ${stage}/release_x86/lib/libssl.a ${stage}/release_arm64/lib/libssl.a -output ${stage}/lib/release/libssl.a

            # copy headers these have been verified to be equivalent in this version of openssl
            mv $stage/release_x86/include/openssl/* $stage/include/openssl

        ;;

        linux*)
            # Linux build environment at Linden comes pre-polluted with stuff that can
            # seriously damage 3rd-party builds.  Environmental garbage you can expect
            # includes:
            #
            #    DISTCC_POTENTIAL_HOSTS     arch           root        CXXFLAGS
            #    DISTCC_LOCATION            top            branch      CC
            #    DISTCC_HOSTS               build_name     suffix      CXX
            #    LSDISTCC_ARGS              repo           prefix      CFLAGS
            #    cxx_version                AUTOBUILD      SIGN        CPPFLAGS
            #
            # So, clear out bits that shouldn't affect our configure-directed build
            # but which do nonetheless.
            #
            # unset DISTCC_HOSTS CC CXX CFLAGS CPPFLAGS CXXFLAGS

            # Default target per AUTOBUILD_ADDRSIZE
            opts="${TARGET_OPTS:--m$AUTOBUILD_ADDRSIZE}"
            DEBUG_COMMON_FLAGS="$opts -Og -g -fPIC -DPIC"
            RELEASE_COMMON_FLAGS="$opts -O3 -g -fPIC -DPIC -fstack-protector-strong -D_FORTIFY_SOURCE=2"
            DEBUG_CFLAGS="$DEBUG_COMMON_FLAGS"
            RELEASE_CFLAGS="$RELEASE_COMMON_FLAGS"
            DEBUG_CXXFLAGS="$DEBUG_COMMON_FLAGS -std=c++17"
            RELEASE_CXXFLAGS="$RELEASE_COMMON_FLAGS -std=c++17"
            DEBUG_CPPFLAGS="-DPIC"
            RELEASE_CPPFLAGS="-DPIC"

            # Handle any deliberate platform targeting
            if [ -z "${TARGET_CPPFLAGS:-}" ]; then
                # Remove sysroot contamination from build environment
                unset CPPFLAGS
            else
                # Incorporate special pre-processing flags
                export CPPFLAGS="${TARGET_CPPFLAGS:-}"
            fi

            # Fix up path for pkgconfig
            if [ -d "$stage/packages/lib/release/pkgconfig" ]; then
                fix_pkgconfig_prefix "$stage/packages"
            fi

            OLD_PKG_CONFIG_PATH="${PKG_CONFIG_PATH:-}"

            # Force static linkage to libz by moving .sos out of the way
            trap restore_sos EXIT
            for solib in "${stage}"/packages/lib/{debug,release}/*.so*; do
                if [ -f "$solib" ]; then
                    mv -f "$solib" "$solib".disable
                fi
            done

            # '--libdir' functions a bit different than usual.  Here it names
            # a part of a directory path, not the entire thing.  Same with
            # '--openssldir' as well.
            # "shared" means build shared and static, instead of just static.
            export PKG_CONFIG_PATH="$stage/packages/lib/debug/pkgconfig:${OLD_PKG_CONFIG_PATH}"

            ./Configure zlib no-zlib-dynamic threads no-shared debug-linux-x86_64 "$DEBUG_CFLAGS" \
                --with-rand-seed="os,rdcpu" \
                --prefix="${stage}" --libdir="lib/debug" --openssldir="share" \
                --with-zlib-include="$stage/packages/include/zlib" --with-zlib-lib="$stage"/packages/lib/debug/
            make -j$AUTOBUILD_CPU_COUNT
            make install_sw

            sed -i s#"${stage}"#"\${AUTOBUILD_PACKAGES_DIR}"#g ${stage}/lib/debug/pkgconfig/**.pc

            # conditionally run unit tests
            if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                make test
            fi

            make clean

            export PKG_CONFIG_PATH="$stage/packages/lib/release/pkgconfig:${OLD_PKG_CONFIG_PATH}"

            ./Configure zlib no-zlib-dynamic threads no-shared linux-x86_64 "$RELEASE_CFLAGS" \
                --with-rand-seed="os,rdcpu" \
                --prefix="${stage}" --libdir="lib/release" --openssldir="share" \
                --with-zlib-include="$stage/packages/include/zlib" --with-zlib-lib="$stage"/packages/lib/release/
            make -j$AUTOBUILD_CPU_COUNT
            make install_sw

            sed -i s#"${stage}"#"\${AUTOBUILD_PACKAGES_DIR}"#g ${stage}/lib/release/pkgconfig/**.pc

            # conditionally run unit tests
            if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                make test
            fi

            make clean
        ;;
    esac
    mkdir -p "$stage/LICENSES"
    cp -a LICENSE "$stage/LICENSES/openssl.txt"
popd

version=$(sed -n -E 's/# define OPENSSL_VERSION_STR "([0-9.]+)"/\1/p' "${stage}/include/openssl/opensslv.h")
echo "${version}" > "${stage}/VERSION.txt"
