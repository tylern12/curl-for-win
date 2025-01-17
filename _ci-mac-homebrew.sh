#!/usr/bin/env bash

# Copyright (C) Viktor Szakats. See LICENSE.md
# SPDX-License-Identifier: MIT

# shellcheck disable=SC3040
set -o xtrace -o errexit -o nounset; [ -n "${BASH:-}${ZSH_NAME:-}" ] && set -o pipefail

export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_ANALYTICS=1
time brew update >/dev/null
time brew install xz gnu-tar mingw-w64 llvm gettext \
                  jq dos2unix osslsigncode openssh
[[ "${APPVEYOR_REPO_BRANCH:-}" = *'boringssl'* ]] && time brew install go nasm
time brew install --cask wine-stable
time wineboot --init

./_build.sh
