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

if [[ "$OSTYPE" == "cygwin" || "$OSTYPE" == "msys" ]] ; then
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

[ -f "$stage"/packages/include/zlib-ng/zlib.h ] || \
{ echo "You haven't yet run 'autobuild install'." 1>&2; exit 1; }

# load autobuild provided shell functions and variables
source_environment_tempfile="$stage/source_environment.sh"
"$autobuild" source_environment > "$source_environment_tempfile"
. "$source_environment_tempfile"

# remove_cxxstd
source "$(dirname "$AUTOBUILD_VARIABLES_FILE")/functions"

OPENSSL_SOURCE_DIR="openssl"

pushd "$OPENSSL_SOURCE_DIR"
    case "$AUTOBUILD_PLATFORM" in

        windows*)
            # configure won't work with VC-* builds undex cygwin's perl, use window's one
            export PATH="/c/Strawberry/perl/bin:$PATH"

            load_vsvars

            mkdir -p "$stage/lib/debug"
            mkdir -p "$stage/lib/release"

            if [ "$AUTOBUILD_ADDRSIZE" = 32 ]
            then
                targetname=VC-WIN32
            else
                # might require running vcvars64.bat from VS studio
                targetname=VC-WIN64A
            fi

            # Set CFLAGS directly, rather than on the Configure command line.
            # Configure promises to pass through -switches, but is completely
            # confounded by /switches. If you change /switches to -switches
            # using bash string magic, Configure does pass them through --
            # only to have cl.exe ignore them with extremely verbose warnings!
            # CFLAGS can accept /switches and correctly pass them to cl.exe.
            opts="$(replace_switch /Zi /Z7 $LL_BUILD_DEBUG)"
            plainopts="$(remove_switch /GR $(remove_cxxstd $opts))"
            export CFLAGS="$plainopts"
            export CXXFLAGS="$opts"

            # Debug Build
            perl Configure "debug-$targetname" zlib no-zlib-dynamic threads no-shared -DUNICODE -D_UNICODE /FS \
                --with-zlib-include="$(cygpath -w "$stage/packages/include/zlib-ng")" \
                --with-zlib-lib="$(cygpath -w "$stage/packages/lib/debug/zlibd.lib")"

            jom

            # conditionally run unit tests
            if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                jom test
            fi

            cp -a {libcrypto,libssl}.lib "$stage/lib/debug"

            # Clean
            nmake distclean

            # Now set up Release flags
            opts="$(replace_switch /Zi /Z7 $LL_BUILD_RELEASE)"
            plainopts="$(remove_switch /GR $(remove_cxxstd $opts))"
            export CFLAGS="$plainopts"
            export CXXFLAGS="$opts"

            perl Configure "$targetname" zlib no-zlib-dynamic threads no-shared -DUNICODE -D_UNICODE -FS \
                --with-zlib-include="$(cygpath -w "$stage/packages/include/zlib-ng")" \
                --with-zlib-lib="$(cygpath -w "$stage/packages/lib/release/zlib.lib")"

            jom

            # Publish headers
            mkdir -p "$stage/include/openssl"

            # conditionally run unit tests
            if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                jom test
            fi

            cp -a {libcrypto,libssl}.lib "$stage/lib/release"

            # Publish headers
            mkdir -p "$stage/include/openssl"
            cp -a include/openssl/*.h "$stage/include/openssl"
        ;;

        darwin*)
            # Install name for dylibs based on major version number
            # Not clear exactly why Configure/make generates lib*.1.0.0.dylib
            # for ${major_version}.${minor_version}.${build_version} == 1.0.1,
            # but obviously we must correctly predict the dylib filenames.
            # crypto_target_name="libcrypto.${major_version}.${minor_version}.dylib"
            # crypto_install_name="@executable_path/../Resources/${crypto_target_name}"
            # ssl_target_name="libssl.${major_version}.${minor_version}.dylib"
            # ssl_install_name="@executable_path/../Resources/${ssl_target_name}"

            # Force static linkage by moving .dylibs out of the way
            trap restore_dylibs EXIT
            for dylib in "$stage/packages/lib"/{debug,release}/*.dylib; do
                if [ -f "$dylib" ]; then
                    mv "$dylib" "$dylib".disable
                fi
            done

            # deploy target
            export MACOSX_DEPLOYMENT_TARGET=${LL_BUILD_DARWIN_DEPLOY_TARGET}

            for arch in x86_64 arm64 ; do
                opts="${TARGET_OPTS:-$LL_BUILD_RELEASE}"
                cc_opts="$(remove_cxxstd $opts)"
                ld_opts="-Wl,-headerpad_max_install_names"

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
                    packed+=("${pack[*]:-}")
                    pack=()
                }
                for opt in $cc_opts $ld_opts
                do
                if [ "x${opt#-}" != "x$opt" ]
                then
                    # 'opt' does indeed start with dash.
                    flush
                fi
                # append 'opt' to 'pack' array
                pack+=("$opt")
                done
                # When we exit the above loop, we've got one more pending entry in
                # 'pack'. Flush that too.
                flush
                # We always have an extra first entry in 'packed'. Get rid of that.
                unset packed[0]

                mkdir -p "build_$arch"
                pushd "build_$arch"
                    CFLAGS="$cc_opts" \
                    CXXFLAGS="$opts" \
                    LDFLAGS="$ld_opts" \
                    ../Configure --release zlib no-zlib-dynamic threads no-shared darwin64-"$arch"-cc \
                        --prefix="$stage" --libdir="lib/release/$arch" --openssldir="share" \
                        --with-zlib-include="$stage/packages/include/zlib-ng" \
                        --with-zlib-lib="$stage/packages/lib/release" \
                        "${packed[@]}"
                        make depend
                        make -j$AUTOBUILD_CPU_COUNT
                        # Avoid plain 'make install' because, at least on Yosemite,
                        # installing the man pages into the staging area creates problems
                        # due to the number of symlinks. Thanks to Cinder for suggesting
                        # this make target.
                        make install_sw

                        # Modify .dylib path information.  Do this after install
                        # to the copies rather than built or the dylib's will be
                        # linked again wiping out the install_name.
                        # crypto_stage_name="${stage}/lib/release/${crypto_target_name}"
                        # ssl_stage_name="${stage}/lib/release/${ssl_target_name}"
                        # chmod u+w "${crypto_stage_name}" "${ssl_stage_name}"
                        # install_name_tool -id "${ssl_install_name}" "${ssl_stage_name}"
                        # install_name_tool -id "${crypto_install_name}" "${crypto_stage_name}"
                        # install_name_tool -change "${crypto_stage_name}" "${crypto_install_name}" "${ssl_stage_name}"

                        # conditionally run unit tests
                        if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                            make test
                        fi

                        make clean
                popd
            done

            # create stage structure
            mkdir -p "$stage/lib/release"

           # create fat libraries
            lipo -create -output ${stage}/lib/release/libcrypto.a ${stage}/lib/release/x86_64/libcrypto.a ${stage}/lib/release/arm64/libcrypto.a
            lipo -create -output ${stage}/lib/release/libssl.a ${stage}/lib/release/x86_64/libssl.a ${stage}/lib/release/arm64/libssl.a
        ;;

        linux*)
            # Default target per AUTOBUILD_ADDRSIZE
            opts="${TARGET_OPTS:--m$AUTOBUILD_ADDRSIZE $LL_BUILD_RELEASE}"
            opts="$(remove_cxxstd $opts)"

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

            ./Configure zlib no-zlib-dynamic threads no-shared "$targetname" "$opts" \
                --prefix="$stage" --libdir="lib/release" --openssldir="share" \
                --with-zlib-include="$stage/packages/include/zlib-ng" \
                --with-zlib-lib="$stage"/packages/lib/release/
            make depend
            make -j$AUTOBUILD_CPU_COUNT
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
            # chmod u+w "$stage"/lib/release/lib{crypto,ssl}.so*
        ;;
    esac
    mkdir -p "$stage/LICENSES"
    cp -a LICENSE "$stage/LICENSES/openssl.txt"
popd

mkdir -p "$stage"/docs/openssl/
