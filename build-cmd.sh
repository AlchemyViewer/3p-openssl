#!/usr/bin/env bash

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
# Look in crypto/opensslv.h instead of the more obvious
# include/openssl/opensslv.h because the latter is (supposed to be) a symlink
# to the former. That works on Mac and Linux but not Windows: on Windows we
# get a plain text file containing the relative path to crypto/opensslv.h, and
# a very strange "version number" because perl can't find
# OPENSSL_VERSION_NUMBER. (Sigh.)
raw_version=$(perl -ne 's/#\s*define\s+OPENSSL_VERSION_NUMBER\s+([\d]+)/$1/ && print' "${OPENSSL_SOURCE_DIR}/crypto/opensslv.h")

major_version=$(echo ${raw_version:2:1})
minor_version=$((10#$(echo ${raw_version:3:2})))
build_version=$((10#$(echo ${raw_version:5:2})))

patch_level_hex=$(echo $raw_version | cut -c 8-9)
patch_level_dec=$((16#$patch_level_hex))
str="abcdefghijklmnopqrstuvwxyz"
patch_level_version=$(echo ${str:patch_level_dec-1:1})

version_str=${major_version}.${minor_version}.${build_version}${patch_level_version}

build=${AUTOBUILD_BUILD_ID:=0}
echo "${version_str}.${build}" > "${stage}/VERSION.txt"

pushd "$OPENSSL_SOURCE_DIR"
    case "$AUTOBUILD_PLATFORM" in

        windows*)
            load_vsvars

            mkdir -p "$stage/lib/release"

            if [ "$AUTOBUILD_ADDRSIZE" = 32 ]
            then
                targetname=VC-WIN32
                batname=do_ms
            else
                targetname=VC-WIN64A
                batname=do_win64a
            fi

            # Set CFLAG directly, rather than on the Configure command line.
            # Configure promises to pass through -switches, but is completely
            # confounded by /switches. If you change /switches to -switches
            # using bash string magic, Configure does pass them through --
            # only to have cl.exe ignore them with extremely verbose warnings!
            # CFLAG can accept /switches and correctly pass them to cl.exe.
            export CFLAG="$LL_BUILD_RELEASE"

            # disable idea cypher per Phoenix's patent concerns (DEV-22827)
            perl Configure "$targetname" no-asm zlib threads -DNO_WINDOWS_BRAINDEATH \
                --with-zlib-include="$(cygpath -w "$stage/packages/include/zlib")" \
                --with-zlib-lib="$(cygpath -w "$stage/packages/lib/release/zlib.lib")"

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

            # Not using NASM
            ./ms/"$batname.bat"

            nmake -f ms/ntdll.mak

            # conditionally run unit tests
            if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                pushd out32dll
                    # linden_test.bat is a clone of test.bat with unavailable
                    # tests removed and the return status changed to fail if a problem occurs.
                    ../ms/linden_test.bat
                popd
            fi

            cp -a out32dll/{libeay32,ssleay32}.{lib,dll} "$stage/lib/release"

            # Clean
            nmake -f ms/ntdll.mak vclean

            # Publish headers
            mkdir -p "$stage/include/openssl"

            # These files are symlinks in the SSL dist but just show up as text files
            # on windows that contain a string to their source.  So run some perl to
            # copy the right files over. Note, even a 64-bit Windows build
            # puts header files into inc32/openssl!
            perl ../copy-windows-links.pl \
                "inc32/openssl" "$(cygpath -w "$stage/include/openssl")"
        ;;

        darwin*)
            # workaround for finding makedepend on OS X
            export PATH="$PATH":/usr/X11/bin/

            # Install name for dylibs based on major version number
            # Not clear exactly why Configure/make generates lib*.1.0.0.dylib
            # for ${major_version}.${minor_version}.${build_version} == 1.0.1,
            # but obviously we must correctly predict the dylib filenames.
            crypto_target_name="libcrypto.${major_version}.0.0.dylib"
            crypto_install_name="@executable_path/../Resources/${crypto_target_name}"
            ssl_target_name="libssl.${major_version}.0.0.dylib"
            ssl_install_name="@executable_path/../Resources/${ssl_target_name}"

            # Force static linkage by moving .dylibs out of the way
            trap restore_dylibs EXIT
            for dylib in "$stage/packages/lib"/{debug,release}/*.dylib; do
                if [ -f "$dylib" ]; then
                    mv "$dylib" "$dylib".disable
                fi
            done

            # Normally here we'd insert -arch $AUTOBUILD_CONFIGURE_ARCH before
            # $LL_BUILD_RELEASE. But the way we must pass these $opts into
            # Configure doesn't seem to work for -arch: we get tons of:
            # clang: warning: argument unused during compilation: '-arch=x86_64'
            # Anyway, selection of $targetname (below) appears to handle the
            # -arch switch implicitly.
            opts="${TARGET_OPTS:-$LL_BUILD_RELEASE}"
            # As of 2017-09-08:
            # clang: error: unknown argument: '-gdwarf-with-dsym'
            opts="${opts/-gdwarf-with-dsym/-gdwarf-2}"
            export CFLAG="$opts"
            export LDFLAGS="-Wl,-headerpad_max_install_names"

            if [ "$AUTOBUILD_ADDRSIZE" = 32 ]
            then
                targetname='darwin-i386-cc 386'
            else
                targetname='darwin64-x86_64-cc'
            fi

            # It seems to be important to Configure to pass (e.g.)
            # "-iwithsysroot=/some/path" instead of just glomming them on
            # as separate arguments. So make a pass over $opts, collecting
            # switches with args in that form into a bash array.
            packed=()
            pack=()
            function flush {
                local IFS="="
                # Flush 'pack' array to the next entry of 'packed'.
                # ${pack[*]} concatenates all of pack's entries into a single
                # string separated by the first char from $IFS.
                packed[${#packed[*]}]="${pack[*]:-}"
                pack=()
            }
            for opt in $opts $LDFLAGS
            do 
               if [ "${opt#-}" != "$opt" ]
               then
                   # 'opt' does indeed start with dash.
                   flush
               fi
               # append 'opt' to 'pack' array
               pack[${#pack[*]}]="$opt"
            done
            # When we exit the above loop, we've got one more pending entry in
            # 'pack'. Flush that too.
            flush
            # We always have an extra first entry in 'packed'. Get rid of that.
            unset packed[0]

            # Release
            ./Configure zlib threads shared no-gost $targetname \
                --prefix="$stage" --libdir="lib/release" --openssldir="share" \
                --with-zlib-include="$stage/packages/include/zlib" \
                --with-zlib-lib="$stage/packages/lib/release" \
                "${packed[@]}"
            make depend
            make
            # Avoid plain 'make install' because, at least on Yosemite,
            # installing the man pages into the staging area creates problems
            # due to the number of symlinks. Thanks to Cinder for suggesting
            # this make target.
            make install_sw

            # Modify .dylib path information.  Do this after install
            # to the copies rather than built or the dylib's will be
            # linked again wiping out the install_name.
            crypto_stage_name="${stage}/lib/release/${crypto_target_name}"
            ssl_stage_name="${stage}/lib/release/${ssl_target_name}"
            chmod u+w "${crypto_stage_name}" "${ssl_stage_name}"
            install_name_tool -id "${ssl_install_name}" "${ssl_stage_name}"
            install_name_tool -id "${crypto_install_name}" "${crypto_stage_name}"
            install_name_tool -change "${crypto_stage_name}" "${crypto_install_name}" "${ssl_stage_name}"

            # conditionally run unit tests
            if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                make test
            fi

            make clean
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
			DEBUG_CLFAGS="$DEBUG_COMMON_FLAGS"
			RELEASE_CFLAGS="$RELEASE_COMMON_FLAGS"
            DEBUG_CXXLFAGS="$DEBUG_COMMON_FLAGS -std=c++17"
			RELEASE_CXXFLAGS="$RELEASE_COMMON_FLAGS -std=c++17"
            DEBUG_CPPLFAGS="-DPIC"
			RELEASE_CPPFLAGS="-DPIC"

            # Handle any deliberate platform targeting
            if [ -z "${TARGET_CPPFLAGS:-}" ]; then
                # Remove sysroot contamination from build environment
                unset CPPFLAGS
            else
                # Incorporate special pre-processing flags
                export CPPFLAGS="${TARGET_CPPFLAGS:-}"
            fi

            # Force static linkage to libz by moving .sos out of the way
            trap restore_sos EXIT
            for solib in "${stage}"/packages/lib/debug/*.so* "${stage}"/packages/lib/release/*.so*; do
                if [ -f "$solib" ]; then
                    mv -f "$solib" "$solib".disable
                fi
            done

            if [ "$AUTOBUILD_ADDRSIZE" = 32 ]
            then
                targetname='linux-generic32'
            else
                targetname='linux-x86_64'
            fi

            # '--libdir' functions a bit different than usual.  Here it names
            # a part of a directory path, not the entire thing.  Same with
            # '--openssldir' as well.
            # "shared" means build shared and static, instead of just static.

            ./Configure zlib threads shared debug-linux-x86_64 "$DEBUG_CLFAGS" \
                --prefix="$stage" --libdir="lib/debug" --openssldir="share" \
                --with-zlib-include="$stage/packages/include/zlib" --with-zlib-lib="$stage"/packages/lib/debug/
            make depend
            make
            make install_sw

            # conditionally run unit tests
            if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                make test
            fi

            make clean

            ./Configure zlib threads shared "$targetname" "$RELEASE_CFLAGS" \
                --prefix="$stage" --libdir="lib/release" --openssldir="share" \
                --with-zlib-include="$stage/packages/include/zlib" \
                --with-zlib-lib="$stage"/packages/lib/release/
            make depend
            make
            make install_sw

            # conditionally run unit tests
            if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                make test
            fi

            make clean

            # By default, 'make install' leaves even the user write bit off.
            # This causes trouble for us down the road, along about the time
            # the consuming build tries to strip libraries.  It's easier to
            # make writable here than fix the viewer packaging.
            chmod u+w "$stage"/lib/release/lib{crypto,ssl}.so*
        ;;
    esac
    mkdir -p "$stage/LICENSES"
    cp -a LICENSE "$stage/LICENSES/openssl.txt"
popd

mkdir -p "$stage"/docs/openssl/
cp -a README.Linden "$stage"/docs/openssl/
