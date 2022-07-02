#!/bin/sh

# Copyright 2014-present Viktor Szakats. See LICENSE.md

# shellcheck disable=SC3040
set -o xtrace -o errexit -o nounset; [ -n "${BASH:-}${ZSH_NAME:-}" ] && set -o pipefail

export _NAM _VER _OUT _BAS _DST

_NAM="$(basename "$0" | cut -f 1 -d '.')"; [ -n "${2:-}" ] && _NAM="$2"
_VER="$1"

(
  cd "${_NAM}" || exit 0

  if [ "${_OS}" = 'win' ]; then
    # Required on MSYS2 for pod2man and pod2html in 'make install' phase
    export PATH="${PATH}:/usr/bin/core_perl"
  fi

  readonly _ref='CHANGES.md'

  case "${_OS}" in
    bsd|mac) unixts="$(TZ=UTC stat -f '%m' "${_ref}")";;
    *)       unixts="$(TZ=UTC stat --format '%Y' "${_ref}")";;
  esac

  # Build

  rm -r -f "${_PKGDIR}" "${_BLDDIR}"

  [ "${_CPU}" = 'x86' ] && options='mingw'
  [ "${_CPU}" = 'x64' ] && options='mingw64'
  [ "${_CPU}" = 'a64' ] && options='...'  # TODO

  options="${options} ${_LDFLAGS_GLOBAL} ${_LIBS_GLOBAL} ${_CFLAGS_GLOBAL} ${_CPPFLAGS_GLOBAL}"

  options="${options} no-filenames"
  [ "${_CPU}" = 'x64' ] && options="${options} enable-ec_nistp_64_gcc_128"
  if [ "${_CPU}" = 'x86' ]; then
    options="${options} -D_WIN32_WINNT=0x0501"  # For Windows XP compatibility
  else
    options="${options} -DUSE_BCRYPTGENRANDOM -lbcrypt"
  fi

  if [ "${_CC}" = 'clang' ]; then
    # To avoid warnings when passing C compiler options to the linker
    options="${options} -Wno-unused-command-line-argument"
    export CC="${_CC_GLOBAL}"
    _CONF_CCPREFIX=
  else
    _CONF_CCPREFIX="${_CCPREFIX}"
  fi

  # Patch OpenSSL ./Configure to:
  # - make it accept Windows-style absolute paths as --prefix. Without the
  #   patch it misidentifies all such absolute paths as relative ones and
  #   aborts.
  #   Reported: https://github.com/openssl/openssl/issues/9520
  # - allow no-apps option to save time building openssl.exe.
  sed \
    -e 's|die "Directory given with --prefix|print "Directory given with --prefix|g' \
    -e 's|"aria",$|"apps", "aria",|g' \
    < ./Configure > ./Configure-patched
  chmod a+x ./Configure-patched

  # Space or backslash not allowed. Needs to be a folder restricted
  # to Administrators across Windows installations, versions and
  # configurations. We do avoid using the new default prefix set since
  # OpenSSL 1.1.1d, because by using the C:\Program Files*\ value, the
  # prefix remains vulnerable on localized Windows versions. The default
  # below gives a "more secure" configuration for most Windows installations.
  # Also notice that said OpenSSL default breaks OpenSSL's own build system
  # when used in cross-build scenarios. I submitted the working patch, but
  # closed subsequently due to mixed/no response. The secure solution would
  # be to disable loading anything from hard-coded paths and preferably to
  # detect OS location at runtime and adjust config paths accordingly; none
  # supported by OpenSSL.
  _win_prefix='C:/Windows/System32/OpenSSL'
  _ssldir="ssl"

  # 'no-dso' implies 'no-dynamic-engine' which in turn compiles in these
  # engines non-dynamically. To avoid them, along with their system DLL
  # dependencies and DLL imports, we explicitly disable them one by one in
  # the 'no-capieng ...' line.

  (
    mkdir "${_BLDDIR}"; cd "${_BLDDIR}"
    # shellcheck disable=SC2086
    ../Configure-patched ${options} \
      "--cross-compile-prefix=${_CONF_CCPREFIX}" \
      -Wl,--nxcompat -Wl,--dynamicbase \
      no-legacy \
      no-apps \
      no-capieng no-loadereng no-padlockeng \
      no-module \
      no-dso \
      no-shared \
      no-idea \
      no-unit-test \
      no-tests \
      no-makedepend \
      "--prefix=${_win_prefix}" \
      "--openssldir=${_ssldir}"
  )

  SOURCE_DATE_EPOCH=${unixts} TZ=UTC make --directory="${_BLDDIR}" --jobs=2
  # Ending slash required.
  make --directory="${_BLDDIR}" --jobs=2 install "DESTDIR=$(pwd)/${_PKGDIR}/" >/dev/null # 2>&1

  # OpenSSL 3.x does not strip the drive letter anymore:
  #   ./openssl/${_PKGDIR}/C:/Windows/System32/OpenSSL
  # Some tools (e.g CMake) become weird when colons appear in
  # a filename, so move results to a sane, standard path:

  _pkg="${_PP}"  # DESTDIR= + _PREFIX
  mkdir -p "./${_pkg}"
  mv "${_PKGDIR}/${_win_prefix}"/* "${_pkg}"

  # Rename 'lib64' to 'lib'. This is what most packages expect.

  if [ "${_CPU}" = 'x64' ]; then
    mv "${_pkg}/lib64" "${_pkg}/lib"
  fi

  # Delete .pc files
  rm -r -f "${_pkg}"/lib/pkgconfig

  # List files created

  find "${_pkg}" | grep -a -v -F '/share/' | sort

  # Make steps for determinism

  "${_STRIP}" --preserve-dates --enable-deterministic-archives --strip-debug "${_pkg}"/lib/*.a

  touch -c -r "${_ref}" "${_pkg}"/lib/*.a
  touch -c -r "${_ref}" "${_pkg}"/include/openssl/*.h

  # Create package

  _OUT="${_NAM}-${_VER}${_REVSUFFIX}${_PKGSUFFIX}"
  _BAS="${_NAM}-${_VER}${_PKGSUFFIX}"
  _DST="$(mktemp -d)/${_BAS}"

  mkdir -p "${_DST}/include/openssl"
  mkdir -p "${_DST}/lib"

  cp -f -p "${_pkg}"/lib/*.a             "${_DST}/lib"
  cp -f -p "${_pkg}"/include/openssl/*.h "${_DST}/include/openssl/"
  cp -f -p CHANGES.md                    "${_DST}/"
  cp -f -p LICENSE.txt                   "${_DST}/"
  cp -f -p README.md                     "${_DST}/"
  cp -f -p FAQ.md                        "${_DST}/"
  cp -f -p NEWS.md                       "${_DST}/"

  [ "${_NAM}" = 'openssl-quic' ] && cp -f -p README-OpenSSL.md "${_DST}/"

  if [ "${_CPU}" = 'x86' ] && [ -r ms/applink.c ]; then
    touch -c -r "${_ref}" ms/applink.c
    cp -f -p ms/applink.c "${_DST}/include/openssl/"
  fi

  ../_pkg.sh "$(pwd)/${_ref}"
)
