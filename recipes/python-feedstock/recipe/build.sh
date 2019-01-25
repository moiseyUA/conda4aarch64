#!/bin/bash

# The LTO/PGO information was sourced from @pitrou and the Debian rules file in:
# http://http.debian.net/debian/pool/main/p/python3.6/python3.6_3.6.2-2.debian.tar.xz
# https://packages.debian.org/source/sid/python3.6
# or:
# http://bazaar.launchpad.net/~doko/python/pkg3.5-debian/view/head:/rules#L255
# .. but upstream regrtest.py now has --pgo (since >= 3.6) and skips tests that are:
# "not helpful for PGO".

VER=${PKG_VERSION%.*}
VERNODOTS=${VER//./}
CONDA_FORGE=no

_buildd_static=build-static
_buildd_shared=build-shared
_ENABLE_SHARED=--enable-shared
# We *still* build a shared lib here for non-static embedded use cases
_DISABLE_SHARED=--disable-shared
# Hack to allow easily comparing static vs shared interpreter performance
# .. hack because we just build it shared in both the build-static and
# build-shared directories.
# Yes this hack is a bit confusing, sorry about that.
if [[ ${PY_INTERP_LINKAGE_NATURE} == shared ]]; then
  _DISABLE_SHARED=--enable-shared
  _ENABLE_SHARED=--enable-shared
fi

# For debugging builds, set this to 0 to disable profile-guided optimization
if [[ ${DEBUG_C} == yes ]]; then
  _OPTIMIZED=no
else
  _OPTIMIZED=yes
fi

declare -a _dbg_opts
if [[ ${DEBUG_PY} == yes ]]; then
  # This Python will not be usable with non-debug Python modules.
  _dbg_opts+=(--with-pydebug)
  DBG=d
else
  DBG=
fi

ABIFLAGS=${DBG}m

# This is the mechanism by which we fall back to default gcc, but having it defined here
# would probably break the build by using incorrect settings and/or importing files that
# do not yet exist.
unset _PYTHON_SYSCONFIGDATA_NAME
unset _CONDA_PYTHON_SYSCONFIGDATA_NAME

# Remove bzip2's shared library if present,
# as we only want to link to it statically.
# This is important in cases where conda
# tries to update bzip2.
find "${PREFIX}/lib" -name "libbz2*${SHLIB_EXT}*" | xargs rm -fv {}

# Prevent lib/python${VER}/_sysconfigdata_*.py from ending up with full paths to these things
# in _build_env because _build_env will not get found during prefix replacement, only _h_env_placeh ...
AR=$(basename "${AR}")

# CC must contain the string 'gcc' or else distutils thinks it is on macOS and uses '-R' to set rpaths.
if [[ ${HOST} =~ .*darwin.* ]]; then
  CC=$(basename "${CC}")
else
  CC=$(basename "${GCC}")
fi
CXX=$(basename "${CXX}")
RANLIB=$(basename "${RANLIB}")
READELF=$(basename "${READELF}")

if [[ ${HOST} =~ .*darwin.* ]] && [[ -n ${CONDA_BUILD_SYSROOT} ]]; then
  # Python's setup.py will figure out that this is a macOS sysroot.
  CFLAGS="-isysroot ${CONDA_BUILD_SYSROOT} "${CFLAGS}
  LDFLAGS="-isysroot ${CONDA_BUILD_SYSROOT} "${LDFLAGS}
  CPPFLAGS="-isysroot ${CONDA_BUILD_SYSROOT} "${CPPFLAGS}
fi

# Debian uses -O3 then resets it at the end to -O2 in _sysconfigdata.py
if [[ ${_OPTIMIZED} = yes ]]; then
  CPPFLAGS=$(echo "${CPPFLAGS}" | sed "s/-O2/-O3/g")
  CFLAGS=$(echo "${CFLAGS}" | sed "s/-O2/-O3/g")
  CXXFLAGS=$(echo "${CXXFLAGS}" | sed "s/-O2/-O3/g")
fi

if [[ ${CONDA_FORGE} == yes ]]; then
  ${SYS_PYTHON} ${RECIPE_DIR}/brand_python.py
fi

declare -a LTO_CFLAGS

CPPFLAGS=${CPPFLAGS}" -I${PREFIX}/include"

re='^(.*)(-I[^ ]*)(.*)$'
if [[ ${CFLAGS} =~ $re ]]; then
  CFLAGS="${BASH_REMATCH[1]}${BASH_REMATCH[3]}"
fi

# Force rebuild to avoid:
# ../work/Modules/unicodename_db.h:24118:30: note: (near initialization for 'code_hash')
# ../work/Modules/unicodename_db.h:24118:33: warning: excess elements in scalar initializer
#      0, 0, 12018, 0, 0, 0, 0, 0, 4422, 4708, 3799, 119358, 119357, 0, 120510,
#                                  ^~~~
# This should have been fixed by https://github.com/python/cpython/commit/7c69c1c0fba8c1c8ff3969bce4c1135736a4cc58
# .. but that appears incomplete. In particular, the generated files contain:
# /* this file was generated by Tools/unicode/makeunicodedata.py 3.2 */
# .. yet the PR updated to version of makeunicodedata.py to 3.3
# rm -f Modules/unicodedata_db.h Modules/unicodename_db.h
# ${SYS_PYTHON} ${SRC_DIR}/Tools/unicode/makeunicodedata.py
# .. instead we revert this commit for now.

export CPPFLAGS CFLAGS CXXFLAGS LDFLAGS

if [[ ${HOST} =~ .*darwin.* ]]; then
  sed -i -e "s/@OSX_ARCH@/$ARCH/g" Lib/distutils/unixccompiler.py
fi

if [[ "${BUILD}" != "${HOST}" ]] && [[ -n "${BUILD}" ]] && [[ -n "${HOST}" ]]; then
  # Build the exact same Python for the build machine. It would be nice (and might be
  # possible already?) to be able to make this just an 'exact' pinned build dependency
  # of a split-package?
  BUILD_PYTHON_PREFIX=${PWD}/build-python-install
  mkdir build-python-build
  pushd build-python-build
    (unset CPPFLAGS LDFLAGS;
     export CC=/usr/bin/gcc \
            CXX=/usr/bin/g++ \
            CPP=/usr/bin/cpp \
            CFLAGS="-O2" \
            AR=/usr/bin/ar \
            RANLIB=/usr/bin/ranlib \
            LD=/usr/bin/ld && \
      ${SRC_DIR}/configure --build=${BUILD} \
                           --host=${BUILD} \
                           --prefix=${BUILD_PYTHON_PREFIX} \
                           --with-ensurepip=no && \
      make && \
      make install)
    export PATH=${BUILD_PYTHON_PREFIX}/bin:${PATH}
    ln -s ${BUILD_PYTHON_PREFIX}/bin/python${VER} ${BUILD_PYTHON_PREFIX}/bin/python
  popd
  echo "ac_cv_file__dev_ptmx=yes"        > config.site
  echo "ac_cv_file__dev_ptc=yes"        >> config.site
  echo "ac_cv_pthread=yes"              >> config.site
  echo "ac_cv_little_endian_double=yes" >> config.site
  export CONFIG_SITE=${PWD}/config.site
  # This is needed for libffi:
  export PKG_CONFIG_PATH=${PREFIX}/lib/pkgconfig
fi

# This causes setup.py to query the sysroot directories from the compiler, something which
# IMHO should be done by default anyway with a flag to disable it to workaround broken ones.
# Technically, setting _PYTHON_HOST_PLATFORM causes setup.py to consider it cross_compiling
if [[ -n ${HOST} ]]; then
  if [[ ${HOST} =~ .*darwin.* ]]; then
    # Even if BUILD is .*darwin.* you get better isolation by cross_compiling (no /usr/local)
    export _PYTHON_HOST_PLATFORM=darwin
  else
    IFS='-' read -r host_arch host_vendor host_os host_libc <<<"${HOST}"
    export _PYTHON_HOST_PLATFORM=${host_os}-${host_arch}
  fi
fi

# Not used at present but we should run 'make test' and finish up TESTOPTS (see debians rules).
declare -a TEST_EXCLUDES
TEST_EXCLUDES+=(test_ensurepip test_venv)
TEST_EXCLUDES+=(test_tcl test_codecmaps_cn test_codecmaps_hk
                test_codecmaps_jp test_codecmaps_kr test_codecmaps_tw
                test_normalization test_ossaudiodev test_socket)
if [[ ! -f /dev/dsp ]]; then
  TEST_EXCLUDES+=(test_linuxaudiodev test_ossaudiodev)
fi
# hangs on Aarch64, see LP: #1264354
if [[ ${CC} =~ .*-aarch64.* ]]; then
  TEST_EXCLUDES+=(test_faulthandler)
fi
if [[ ${CC} =~ .*-arm.* ]]; then
  TEST_EXCLUDES+=(test_ctypes)
  TEST_EXCLUDES+=(test_compiler)
fi

declare -a _common_configure_args
_common_configure_args+=(--prefix=${PREFIX})
_common_configure_args+=(--build=${BUILD})
_common_configure_args+=(--host=${HOST})
_common_configure_args+=(--enable-ipv6)
_common_configure_args+=(--with-ensurepip=no)
_common_configure_args+=(--with-computed-gotos)
_common_configure_args+=(--with-system-ffi)
_common_configure_args+=(--enable-loadable-sqlite-extensions)
_common_configure_args+=(--with-tcltk-includes="-I${PREFIX}/include")
_common_configure_args+=("--with-tcltk-libs=-L${PREFIX}/lib -ltcl8.6 -ltk8.6")

mkdir -p ${_buildd_shared}
pushd ${_buildd_shared}
  ${SRC_DIR}/configure "${_common_configure_args[@]}" \
                       "${_dbg_opts[@]}" \
                       --oldincludedir=${BUILD_PREFIX}/${HOST}/sysroot/usr/include \
                       --enable-shared
popd

# Add more optimization flags for the static Python interpreter:
declare -a _extra_opts
if [[ ${_OPTIMIZED} == yes ]]; then
  _extra_opts+=(--enable-optimizations)
  _extra_opts+=(--with-lto)
  _MAKE_TARGET=profile-opt
  # To speed up build times during testing (1):
  # _PROFILE_TASK="./python -m test.regrtest --pgo test_builtin"
  if [[ ${CC} =~ .*gcc.* ]]; then
    LTO_CFLAGS+=(-fuse-linker-plugin)
    LTO_CFLAGS+=(-ffat-lto-objects)
    # -flto must come after -flto-partition due to the replacement code
    LTO_CFLAGS+=(-flto-partition=none)
    LTO_CFLAGS+=(-flto)
  else
    # TODO :: Check if -flto=thin gives better results. It is about faster
    #         compilation rather than faster execution so probably not:
    # http://clang.llvm.org/docs/ThinLTO.html
    # http://blog.llvm.org/2016/06/thinlto-scalable-and-incremental-lto.html
    LTO_CFLAGS+=(-flto)
  fi
  export CFLAGS="${CFLAGS} ${LTO_CFLAGS[@]}"
else
  _MAKE_TARGET=
fi

mkdir -p ${_buildd_static}
pushd ${_buildd_static}
  ${SRC_DIR}/configure "${_common_configure_args[@]}" \
                       "${_extra_opts[@]}" \
                       "${_dbg_opts[@]}" \
                       -oldincludedir=${BUILD_PREFIX}/${HOST}/sysroot/usr/include \
                       ${_DISABLE_SHARED}
popd

make -j${CPU_COUNT} -C ${_buildd_static} \
        EXTRA_CFLAGS="${EXTRA_CFLAGS}" \
        ${_MAKE_TARGET}
# To speed up build times during testing (2):
#       ${_MAKE_TARGET} PROFILE_TASK="${_PROFILE_TASK}"

make -j${CPU_COUNT} -C ${_buildd_shared} \
        EXTRA_CFLAGS="${EXTRA_CFLAGS}"
# build a static library with PIC objects
make -j${CPU_COUNT} -C ${_buildd_shared} \
        EXTRA_CFLAGS="${EXTRA_CFLAGS}" \
        LIBRARY=libpython${VER}m-pic.a libpython${VER}m-pic.a

if [[ ${_OPTIMIZED} == yes ]]; then
  make -C ${_buildd_static} install
  declare -a _FLAGS_REPLACE
  _FLAGS_REPLACE+=(-O3)
  _FLAGS_REPLACE+=(-O2)
  _FLAGS_REPLACE+=("-fprofile-use")
  _FLAGS_REPLACE+=("")
  _FLAGS_REPLACE+=("-fprofile-correction")
  _FLAGS_REPLACE+=("")
  _FLAGS_REPLACE+=("-L.")
  _FLAGS_REPLACE+=("")
  for _LTO_CFLAG in "${LTO_CFLAGS[@]}"; do
    _FLAGS_REPLACE+=(${_LTO_CFLAG})
    _FLAGS_REPLACE+=("")
  done
  # Install the shared library (for people who embed Python only, e.g. GDB).
  # Linking module extensions to this on Linux is redundant (but harmless).
  # Linking module extensions to this on Darwin is harmful (multiply defined symbols).
  if [[ ${HOST} =~ .*linux.* ]]; then
    cp -pf ${_buildd_shared}/libpython${VER}m${SHLIB_EXT}.1.0 ${PREFIX}/lib/
    ln -sf ${PREFIX}/lib/libpython${VER}m${SHLIB_EXT}.1.0 ${PREFIX}/lib/libpython${VER}m${SHLIB_EXT}.1
    ln -sf ${PREFIX}/lib/libpython${VER}m${SHLIB_EXT}.1 ${PREFIX}/lib/libpython${VER}m${SHLIB_EXT}
  elif [[ ${HOST} =~ .*darwin.* ]]; then
    cp -pf ${_buildd_shared}/libpython${VER}m${SHLIB_EXT} ${PREFIX}/lib/
  fi
else
  make -C ${_buildd_shared} install
  declare -a _FLAGS_REPLACE
fi

SYSCONFIG=$(find ${_buildd_static}/$(cat ${_buildd_static}/pybuilddir.txt) -name "_sysconfigdata*.py" -print0)
cat ${SYSCONFIG} | ${SYS_PYTHON} "${RECIPE_DIR}"/replace-word-pairs.py \
  "${_FLAGS_REPLACE[@]}"  \
    > ${PREFIX}/lib/python${VER}/$(basename ${SYSCONFIG})
MAKEFILE=$(find ${PREFIX}/lib/python${VER}/ -path "*config-*/Makefile" -print0)
cp ${MAKEFILE} /tmp/Makefile-$$
cat /tmp/Makefile-$$ | ${SYS_PYTHON} "${RECIPE_DIR}"/replace-word-pairs.py \
  "${_FLAGS_REPLACE[@]}"  \
    > ${MAKEFILE}
# Check to see that our differences took.
# echo diff -urN ${SYSCONFIG} ${PREFIX}/lib/python${VER}/$(basename ${SYSCONFIG})
# diff -urN ${SYSCONFIG} ${PREFIX}/lib/python${VER}/$(basename ${SYSCONFIG})

# Python installs python${VER}m and python${VER}, one as a hardlink to the other. conda-build breaks these
# by copying. Since the executable may be static it may be very large so change one to be a symlink
# of the other. In this case, python${VER}m will be the symlink.
if [[ -f ${PREFIX}/bin/python${VER}m ]]; then
  rm -f ${PREFIX}/bin/python${VER}m
  ln -s ${PREFIX}/bin/python${VER} ${PREFIX}/bin/python${VER}m
fi
ln -s ${PREFIX}/bin/python${VER} ${PREFIX}/bin/python
ln -s ${PREFIX}/bin/pydoc${VER} ${PREFIX}/bin/pydoc

# Remove test data to save space
# Though keep `support` as some things use that.
# TODO :: Make a subpackage for this once we implement multi-level testing.
pushd ${PREFIX}/lib/python${VER}
  mkdir test_keep
  mv test/__init__.py test/support test/test_support* test/test_script_helper* test_keep/
  rm -rf test */test
  mv test_keep test
popd

# Size reductions:
pushd ${PREFIX}
  if [[ -f lib/libpython${VER}m.a ]]; then
    chmod +w lib/libpython${VER}m.a
    if [[ -n ${HOST} ]]; then
      ${HOST}-strip -S lib/libpython${VER}m.a
    else
      strip -S lib/libpython${VER}m.a
    fi
  fi
  CONFIG_LIBPYTHON=$(find lib/python${VER}/config-${VER}${DBG}m* -name "libpython${VER}m.a")
  if [[ -f lib/libpython${VER}m.a ]] && [[ -f ${CONFIG_LIBPYTHON} ]]; then
    chmod +w ${CONFIG_LIBPYTHON}
    rm ${CONFIG_LIBPYTHON}
    ln -s ../../libpython${VER}m.a ${CONFIG_LIBPYTHON}
  fi
popd

# Copy sysconfig that gets recorded to a non-default name
#   using the new compilers with python will require setting _PYTHON_SYSCONFIGDATA_NAME
#   to the name of this file (minus the .py extension)
pushd $PREFIX/lib/python${VER}
  # On Python 3.5 _sysconfigdata.py was getting copied in here and compiled for some reason.
  # This breaks our attempt to find the right one as recorded_name.
  find lib-dynload -name "_sysconfigdata*.py*" -exec rm {} \;
  recorded_name=$(find . -name "_sysconfigdata*.py")
  our_compilers_name=_sysconfigdata_$(echo ${HOST} | sed -e 's/[.-]/_/g').py
  mv ${recorded_name} ${our_compilers_name}

  # Copy all "${RECIPE_DIR}"/sysconfigdata/*.py. This is to support cross-compilation. They will be
  # from the previous build unfortunately so care must be taken at version bumps and flag changes.
  SYSCONFIGS=$(find "${RECIPE_DIR}"/sysconfigdata/*.py -name '*sysconfigdata*')
  for SYSCONFIG in ${SYSCONFIGS}; do
    cat ${SYSCONFIG} | sed -e "s|@ABIFLAGS@|${ABIFLAGS}|g" \
                           -e "s|@PYVERNODOTS@|${VERNODOTS}|g" \
                           -e "s|@PYVER@|${VER}|g" > $(basename ${SYSCONFIG})
  done

  if [[ ${HOST} =~ .*darwin.* ]]; then
    cp ${RECIPE_DIR}/sysconfigdata/default/_sysconfigdata_osx.py ${recorded_name}
  else
    if [[ ${HOST} =~ x86_64.* ]]; then
      PY_ARCH=x86_64
    elif [[ ${HOST} =~ i686.* ]]; then
      PY_ARCH=i386
    elif [[ ${HOST} =~ powerpc64le.* ]]; then
      PY_ARCH=powerpc64le
    elif [[ ${HOST} =~ aarch64.* ]]; then
      PY_ARCH=aarch64
    else
      echo "ERROR: Cannot determine PY_ARCH for host ${HOST}"
      exit 1
    fi
    cat ${RECIPE_DIR}/sysconfigdata/default/_sysconfigdata_linux.py | sed "s|@ARCH@|${PY_ARCH}|g" > ${recorded_name}
    mkdir -p ${PREFIX}/compiler_compat
    cp ${LD} ${PREFIX}/compiler_compat/ld
    echo "Files in this folder are to enhance backwards compatibility of anaconda software with older compilers."   > ${PREFIX}/compiler_compat/README
    echo "See: https://github.com/conda/conda/issues/6030 for more information."                                   >> ${PREFIX}/compiler_compat/README
  fi

  # We no longer do this since we use sed to replace some tokens now and copying these fully baked ones back would overwrite that.
  # I should work on something to put the tokens back instead, but also we probably want sysconfig data to be different for debug
  # versus release.
  #
  # Copy the latest sysconfigdata for this platform back to the recipe so we can do full cross-compilation.
  # The [^ ]* part after PKG_VERSION is to catch beta versions encoded into the build string but not the version number (e.g. b3).
  # .. there is no variable set that contains this information, though it would be useful. We do have:
  # .. PKG_BUILD_STRING="placeholder" though (pinging @msarahan about this).
  # [[ -f	"${RECIPE_DIR}"/sysconfigdata/${our_compilers_name} ]] && rm -f	"${RECIPE_DIR}"/sysconfigdata/${our_compilers_name}
  # cat ${our_compilers_name} | sed -e "s|${PREFIX}|/opt/anaconda1anaconda2anaconda3|g" \
  #                                 -e "s|${SRC_DIR}|\${SRC_DIR}|g" \
  #                                 -e "s|${PKG_NAME}-${PKG_VERSION}[^ ]*|\${PKG_NAME}-\${PKG_VERSION}|g" > "${RECIPE_DIR}"/sysconfigdata/${our_compilers_name}
popd