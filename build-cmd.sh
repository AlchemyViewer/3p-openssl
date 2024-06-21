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

if [[ "$OSTYPE" == "cygwin" || "$OSTYPE" == "msys" ]] ; then
    autobuild="$(cygpath -u $AUTOBUILD)"
else
    autobuild="$AUTOBUILD"
fi

top="$(pwd)"
stage="$top/stage"

[ -f "$stage"/packages/include/zlib/zlib.h ] || \
{ echo "You haven't yet run 'autobuild install'." 1>&2; exit 1; }

# load autobuild provided shell functions and variables
source_environment_tempfile="$stage/source_environment.sh"
"$autobuild" source_environment > "$source_environment_tempfile"
. "$source_environment_tempfile"

OPENSSL_SOURCE_DIR="openssl"
# Look in crypto/opensslv.h instead of the more obvious
# include/openssl/opensslv.h because the latter is (supposed to be) a symlink
# to the former. That works on Mac and Linux but not Windows: on Windows we
# get a plain text file containing the relative path to crypto/opensslv.h, and
# a very strange "version number" because perl can't find
# OPENSSL_VERSION_NUMBER. (Sigh.)
raw_version=$(perl -ne 's/#\s*define\s+OPENSSL_VERSION_NUMBER\s+([\d]+)/$1/ && print' "${OPENSSL_SOURCE_DIR}/include/openssl/opensslv.h")

major_version=$(echo ${raw_version:2:1})
minor_version=$((10#$(echo ${raw_version:3:2})))
build_version=$((10#$(echo ${raw_version:5:2})))

patch_level_hex=$(echo $raw_version | cut -c 8-9)
patch_level_dec=$((16#$patch_level_hex))
str="abcdefghijklmnopqrstuvwxyz"
patch_level_version=$(echo ${str:patch_level_dec-1:1})

version_str=${major_version}.${minor_version}.${build_version}${patch_level_version}

echo "${version_str}" > "${stage}/VERSION.txt"

pushd "$OPENSSL_SOURCE_DIR"
    case "$AUTOBUILD_PLATFORM" in

        windows*)
            load_vsvars

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
            # Setup build flags
            C_OPTS_X86="-arch x86_64 $LL_BUILD_RELEASE_CFLAGS"
            C_OPTS_ARM64="-arch arm64 $LL_BUILD_RELEASE_CFLAGS"
            CXX_OPTS_X86="-arch x86_64 $LL_BUILD_RELEASE_CXXFLAGS"
            CXX_OPTS_ARM64="-arch arm64 $LL_BUILD_RELEASE_CXXFLAGS"
            LINK_OPTS_X86="-arch x86_64 $LL_BUILD_RELEASE_LINKER"
            LINK_OPTS_ARM64="-arch arm64 $LL_BUILD_RELEASE_LINKER"

            # deploy target
            export MACOSX_DEPLOYMENT_TARGET=${LL_BUILD_DARWIN_BASE_DEPLOY_TARGET}

            # Release
            mkdir -p "build_x86_release"
            pushd "build_x86_release"
                export CFLAGS="$C_OPTS_X86"
                export CXXLAGS="$CXX_OPTS_X86"
                export LDFLAGS="$LINK_OPTS_X86"
                ../Configure zlib no-zlib-dynamic threads no-shared darwin64-x86_64-cc "$C_OPTS_X86" \
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

            # Release
            mkdir -p "build_arm64_release"
            pushd "build_arm64_release"
                export CFLAGS="$C_OPTS_ARM64"
                export CXXLAGS="$CXX_OPTS_ARM64"
                export LDFLAGS="$LINK_OPTS_ARM64"
                ../Configure zlib no-zlib-dynamic threads no-shared darwin64-arm64-cc "$C_OPTS_ARM64" \
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
            mkdir -p "$stage/lib/release"

           # create fat libraries
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
            unset DISTCC_HOSTS CFLAGS CPPFLAGS CXXFLAGS

            # Default target per --address-size
            opts_c="${TARGET_OPTS:--m$AUTOBUILD_ADDRSIZE $LL_BUILD_RELEASE_CFLAGS}"
            opts_cxx="${TARGET_OPTS:--m$AUTOBUILD_ADDRSIZE $LL_BUILD_RELEASE_CXXFLAGS}"

            # Handle any deliberate platform targeting
            if [ -z "${TARGET_CPPFLAGS:-}" ]; then
                # Remove sysroot contamination from build environment
                unset CPPFLAGS
            else
                # Incorporate special pre-processing flags
                export CPPFLAGS="${TARGET_CPPFLAGS:-}"
            fi

            ./Configure zlib no-zlib-dynamic threads no-shared linux-x86_64 "$opts_c" \
                --with-rand-seed="os,rdcpu" \
                --prefix="${stage}" \
                --with-zlib-include="$stage/packages/include/zlib" --with-zlib-lib="$stage"/packages/lib/release/
            make -j$AUTOBUILD_CPU_COUNT
            make install_sw

            # conditionally run unit tests
            if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                make test
            fi
        ;;
    esac
    mkdir -p "$stage/LICENSES"
    cp -a LICENSE "$stage/LICENSES/openssl.txt"
popd

mkdir -p "$stage"/docs/openssl/
