#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="$ROOT_DIR/addons/sourcemod/scripting"
PLUGIN_DIR="$ROOT_DIR/addons/sourcemod/plugins"
PROJECT_INCLUDE_DIR="$SOURCE_DIR/include"
GOKZ_TOP_SOURCE_DIR="${GOKZ_TOP_SOURCE_DIR:-$HOME/gokz-top-plugins/addons/sourcemod/scripting}"
GOKZ_SOURCE_DIR="${GOKZ_SOURCE_DIR:-$HOME/gokz/addons/sourcemod/scripting}"
if [[ -z "${GOKZ_INCLUDE_DIR:-}" ]]; then
  if [[ -d "$GOKZ_TOP_SOURCE_DIR/include" ]]; then
    GOKZ_INCLUDE_DIR="$GOKZ_TOP_SOURCE_DIR/include"
  else
    GOKZ_INCLUDE_DIR="$GOKZ_SOURCE_DIR/include"
  fi
fi
# RIPExt 等第三方 include 不入库：build.sh 自动下载官方 release 到 .build 缓存
RIPEXT_VERSION="${RIPEXT_VERSION:-1.3.2}"
SOURCEMOD_VERSION="${SOURCEMOD_VERSION:-1.11.0-git6970}"
SOURCEMOD_SERIES="${SOURCEMOD_SERIES:-1.11}"
SOURCEMOD_ARCHIVE="sourcemod-${SOURCEMOD_VERSION}-linux.tar.gz"
SOURCEMOD_DOWNLOAD_URL="${SOURCEMOD_DOWNLOAD_URL:-https://sm.alliedmods.net/smdrop/${SOURCEMOD_SERIES}/${SOURCEMOD_ARCHIVE}}"
SOURCEMOD_BUILD_DIR="${SOURCEMOD_BUILD_DIR:-$ROOT_DIR/.build}"
RIPEXT_BUILD_DIR="$SOURCEMOD_BUILD_DIR/ripext-${RIPEXT_VERSION}"
RIPEXT_INCLUDE_DIR="$RIPEXT_BUILD_DIR/addons/sourcemod/scripting/include"
DOWNLOADED_SOURCEMOD_ROOT="$SOURCEMOD_BUILD_DIR/sourcemod-${SOURCEMOD_VERSION}-linux"
HOST_SOURCEMOD_ROOT="${HOST_SOURCEMOD_ROOT:-$HOME/gokz/sourcemod-${SOURCEMOD_VERSION}-linux}"

find_compiler() {
  local sourcemod_dir="$1"

  if [[ -x "$sourcemod_dir/scripting/spcomp64" ]]; then
    printf '%s\n' "$sourcemod_dir/scripting/spcomp64"
    return 0
  fi

  if [[ -x "$sourcemod_dir/scripting/spcomp" ]]; then
    printf '%s\n' "$sourcemod_dir/scripting/spcomp"
    return 0
  fi

  return 1
}

ensure_sourcemod() {
  local sourcemod_root
  local compiler

  for sourcemod_root in "$HOST_SOURCEMOD_ROOT" "$DOWNLOADED_SOURCEMOD_ROOT"; do
    if compiler="$(find_compiler "$sourcemod_root/addons/sourcemod")"; then
      SOURCEMOD_DIR="$sourcemod_root/addons/sourcemod"
      SPCOMP="$compiler"
      return 0
    fi
  done

  mkdir -p "$DOWNLOADED_SOURCEMOD_ROOT"

  local archive_path="$SOURCEMOD_BUILD_DIR/$SOURCEMOD_ARCHIVE"
  if [[ ! -f "$archive_path" ]]; then
    echo "Downloading SourceMod compiler: $SOURCEMOD_DOWNLOAD_URL"
    curl -fsSL "$SOURCEMOD_DOWNLOAD_URL" -o "$archive_path"
  fi

  tar -xzf "$archive_path" -C "$DOWNLOADED_SOURCEMOD_ROOT"

  if compiler="$(find_compiler "$DOWNLOADED_SOURCEMOD_ROOT/addons/sourcemod")"; then
    SOURCEMOD_DIR="$DOWNLOADED_SOURCEMOD_ROOT/addons/sourcemod"
    SPCOMP="$compiler"
    return 0
  fi

  echo "SourceMod compiler not found after extracting $archive_path" >&2
  exit 1
}

ensure_sourcemod
SOURCEMOD_INCLUDE_DIR="$SOURCEMOD_DIR/scripting/include"

ensure_ripext_include() {
  if [[ -d "$RIPEXT_INCLUDE_DIR" ]]; then
    return 0
  fi

  mkdir -p "$RIPEXT_BUILD_DIR"
  local archive="$SOURCEMOD_BUILD_DIR/sm-ripext-${RIPEXT_VERSION}-linux.zip"
  if [[ ! -f "$archive" ]]; then
    echo "Downloading RIPExt include: $RIPEXT_VERSION"
    curl -fsSL "https://github.com/ErikMinekus/sm-ripext/releases/download/${RIPEXT_VERSION}/sm-ripext-${RIPEXT_VERSION}-linux.zip" -o "$archive"
  fi
  unzip -oq "$archive" -d "$RIPEXT_BUILD_DIR"
}

if [[ ! -d "$GOKZ_INCLUDE_DIR" ]]; then
  echo "GOKZ include directory not found: $GOKZ_INCLUDE_DIR" >&2
  echo "Set GOKZ_INCLUDE_DIR to the server's GOKZ scripting/include directory." >&2
  exit 1
fi

ensure_ripext_include

mkdir -p "$PLUGIN_DIR"

compile_plugin() {
  local source_file="$1"

  echo "Compiling $source_file ..."
  "$SPCOMP" \
    -i "$PROJECT_INCLUDE_DIR" \
    -i "$RIPEXT_INCLUDE_DIR" \
    -i "$GOKZ_INCLUDE_DIR" \
    -i "$SOURCEMOD_INCLUDE_DIR" \
    -o "$PLUGIN_DIR/${source_file%.sp}.smx" \
    "$SOURCE_DIR/$source_file"
}

compile_plugin "core.sp"
compile_plugin "server.sp"
compile_plugin "sync.sp"
compile_plugin "recordguard.sp"
compile_plugin "global.sp"

echo "Build complete. Output: $PLUGIN_DIR"
