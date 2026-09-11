#!/usr/bin/env bash
set -euo pipefail

# OpenAI's Linux documentation links this stable "latest" endpoint directly:
# https://learn.chatgpt.com/docs/linux/linux-app
# No third-party index or inferred versioned URL is used. The authoritative
# version is read from the downloaded Debian package's control metadata.
readonly OFFICIAL_DEB_URL='https://persistent.oaistatic.com/codex-app-prod/linux/deb/latest/chatgpt_amd64.deb'
readonly OFFICIAL_DOC_URL='https://learn.chatgpt.com/docs/linux/linux-app'
readonly DEB_NAME='chatgpt_amd64.deb'

readonly SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly PKGBUILD_PATH="${SCRIPT_DIR}/PKGBUILD"
readonly INSTALL_PATH="${SCRIPT_DIR}/chatgpt-bin.install"
readonly METADATA_DIR="${SCRIPT_DIR}/upstream-metadata"

MODE='update'
WORK_DIR=''
DOWNLOADED_DEB=''
CONTROL_DIR=''
CONTROL_ARCHIVE=''
DATA_ARCHIVE=''
CONTROL_MEMBER=''
DATA_MEMBER=''
LATEST_VERSION=''
CURRENT_VERSION=''
LATEST_SHA256=''
DEPENDENCY_CHANGED=0
INSTALL_REVIEW_NEEDED=0
PROMOTION_STAGED=0

info() {
  printf '==> %s\n' "$*"
}

warn() {
  printf 'warning: %s\n' "$*" >&2
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: ./update.sh [--check]

  (no option)  Download, inspect, update, and build the latest package.
  --check      Check whether a newer official deb exists; change nothing.
EOF
}

cleanup() {
  local status=$?

  if (( PROMOTION_STAGED != 0 )); then
    rm -f -- \
      "${SCRIPT_DIR}/.${DEB_NAME}.update-new" \
      "${SCRIPT_DIR}/.PKGBUILD.update-new" \
      "${SCRIPT_DIR}"/.*.pkg.tar.*.update-new
    rm -rf -- "${SCRIPT_DIR}/.upstream-metadata.update-new"
  fi

  if [[ -n "${WORK_DIR}" && -d "${WORK_DIR}" ]]; then
    case "${WORK_DIR}" in
      /tmp/chatgpt-arch-update.*|"${TMPDIR:-/tmp}"/chatgpt-arch-update.*)
        rm -rf -- "${WORK_DIR}"
        ;;
      *)
        warn "Refusing to clean unexpected temporary path: ${WORK_DIR}"
        ;;
    esac
  fi

  exit "${status}"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

parse_args() {
  case "${1:-}" in
    '')
      ;;
    --check)
      MODE='check'
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "Unknown option: $1"
      ;;
  esac

  if (( $# > 1 )); then
    usage >&2
    die 'Only one option may be specified.'
  fi
}

require_commands() {
  local command_name
  local -a commands=(ar awk basename cmp cp curl diff find grep ln makepkg mkdir mktemp mv rm sed sha256sum sort tar)

  if [[ "${MODE}" == 'check' ]]; then
    commands=(ar awk cp curl mkdir mktemp rm sed tar)
  fi

  for command_name in "${commands[@]}"; do
    command -v "${command_name}" >/dev/null 2>&1 ||
      die "Required command not found: ${command_name}"
  done
}

read_pkgbuild_value() {
  local key=$1
  awk -F= -v key="${key}" '
    $1 == key {
      value = substr($0, index($0, "=") + 1)
      gsub(/^[[:space:]'\''"]+|[[:space:]'\''"]+$/, "", value)
      print value
      exit
    }
  ' "${PKGBUILD_PATH}"
}

read_control_field() {
  local field=$1
  local control_file=$2

  awk -v wanted="${field}" '
    BEGIN { found = 0 }
    /^[^[:space:]][^:]*:/ {
      if (found) {
        exit
      }
      key = $0
      sub(/:.*/, "", key)
      if (key == wanted) {
        found = 1
        sub(/^[^:]*:[[:space:]]*/, "")
        value = $0
      }
      next
    }
    found && /^[[:space:]]/ {
      sub(/^[[:space:]]+/, "")
      value = value " " $0
    }
    END {
      if (found) {
        print value
      }
    }
  ' "${control_file}"
}

download_latest_deb() {
  local effective_url

  DOWNLOADED_DEB="${WORK_DIR}/${DEB_NAME}"
  info "Downloading the official x64 deb"
  info "Source documentation: ${OFFICIAL_DOC_URL}"

  effective_url=$(curl \
    --fail \
    --location \
    --proto '=https' \
    --proto-redir '=https' \
    --retry 3 \
    --retry-all-errors \
    --show-error \
    --progress-bar \
    --output "${DOWNLOADED_DEB}" \
    --write-out '%{url_effective}' \
    "${OFFICIAL_DEB_URL}") || die 'The official deb download failed.'

  case "${effective_url}" in
    https://persistent.oaistatic.com/*)
      ;;
    *)
      die "Download redirected outside OpenAI's official asset host: ${effective_url}"
      ;;
  esac

  [[ -s "${DOWNLOADED_DEB}" ]] || die 'The downloaded deb is empty.'
}

find_deb_members() {
  local -a control_members=()
  local -a data_members=()
  local member

  while IFS= read -r member; do
    member=${member%/}
    case "${member}" in
      control.tar|control.tar.*)
        control_members+=("${member}")
        ;;
      data.tar|data.tar.*)
        data_members+=("${member}")
        ;;
    esac
  done < <(ar t "${DOWNLOADED_DEB}")

  (( ${#control_members[@]} == 1 )) ||
    die "Expected exactly one control.tar.*, found ${#control_members[@]}."
  (( ${#data_members[@]} == 1 )) ||
    die "Expected exactly one data.tar.*, found ${#data_members[@]}."

  CONTROL_MEMBER=${control_members[0]}
  DATA_MEMBER=${data_members[0]}
}

extract_control_metadata() {
  local debian_format
  local package_name
  local architecture
  local control_file

  debian_format=$(ar p "${DOWNLOADED_DEB}" debian-binary 2>/dev/null) ||
    die 'The download is not a valid Debian package (missing debian-binary).'
  [[ "${debian_format}" == '2.0' ]] ||
    die "Unsupported Debian package format: ${debian_format}"

  find_deb_members

  CONTROL_DIR="${WORK_DIR}/control"
  CONTROL_ARCHIVE="${WORK_DIR}/${CONTROL_MEMBER}"
  mkdir -p -- "${CONTROL_DIR}"
  ar p "${DOWNLOADED_DEB}" "${CONTROL_MEMBER}" > "${CONTROL_ARCHIVE}" ||
    die "Could not extract ${CONTROL_MEMBER}."
  tar -xf "${CONTROL_ARCHIVE}" -C "${CONTROL_DIR}" ||
    die "Could not unpack ${CONTROL_MEMBER}; its compression may be unsupported."

  control_file="${CONTROL_DIR}/control"
  [[ -f "${control_file}" ]] || die 'The control archive does not contain ./control.'

  package_name=$(read_control_field 'Package' "${control_file}")
  architecture=$(read_control_field 'Architecture' "${control_file}")
  LATEST_VERSION=$(read_control_field 'Version' "${control_file}")

  [[ "${package_name}" == 'chatgpt' ]] || die "Unexpected Debian package name: ${package_name}"
  [[ "${architecture}" == 'amd64' ]] || die "Unexpected Debian architecture: ${architecture}"
  [[ -n "${LATEST_VERSION}" ]] || die 'The Debian control file has no Version field.'

  # Arch pkgver cannot contain whitespace, slashes, colons, or hyphens. Abort
  # rather than guessing how to transform a future Debian version scheme.
  [[ "${LATEST_VERSION}" =~ ^[[:alnum:]_.+]+$ ]] ||
    die "Debian Version '${LATEST_VERSION}' is not directly usable as an Arch pkgver; manual review is required."
}

compare_versions() {
  info "Current PKGBUILD version: ${CURRENT_VERSION}"
  info "Latest official deb version: ${LATEST_VERSION}"

  if [[ "${LATEST_VERSION}" == "${CURRENT_VERSION}" ]]; then
    info 'Already up to date; no files were changed and no build was run.'
    exit 0
  fi

  if command -v vercmp >/dev/null 2>&1; then
    if (( $(vercmp "${LATEST_VERSION}" "${CURRENT_VERSION}") < 0 )); then
      die "The official latest endpoint returned older version ${LATEST_VERSION}; refusing to downgrade ${CURRENT_VERSION}."
    fi
  else
    warn 'vercmp is unavailable, so downgrade detection could not be performed.'
  fi

  if [[ "${MODE}" == 'check' ]]; then
    info "Update available: ${CURRENT_VERSION} -> ${LATEST_VERSION}"
    info 'Check mode made no persistent changes.'
    exit 0
  fi
}

extract_and_validate_data() {
  local path
  local data_list="${WORK_DIR}/data-files"
  local critical_paths="${WORK_DIR}/critical-paths"
  local -a required_paths=(
    'etc/apparmor.d/chatgpt'
    'usr/bin/chatgpt'
    'usr/lib/chatgpt/ChatGPT'
    'usr/lib/chatgpt/codex-launcher'
    'usr/share/applications/chatgpt.desktop'
    'usr/share/pixmaps/chatgpt.png'
  )

  DATA_ARCHIVE="${WORK_DIR}/${DATA_MEMBER}"
  ar p "${DOWNLOADED_DEB}" "${DATA_MEMBER}" > "${DATA_ARCHIVE}" ||
    die "Could not extract ${DATA_MEMBER}."
  tar -tf "${DATA_ARCHIVE}" | sed -e 's#^\./##' -e 's#/$##' | sort -u > "${data_list}" ||
    die "Could not list ${DATA_MEMBER}; its compression may be unsupported."

  for path in "${required_paths[@]}"; do
    grep -Fxq "${path}" "${data_list}" || die "Required package path is missing: /${path}"
  done

  grep -Eq '^usr/lib/chatgpt/lib[^/]*\.so([.][0-9]+)*$' "${data_list}" ||
    die 'No bundled shared libraries were found under /usr/lib/chatgpt.'

  grep -E \
    '^(etc/apparmor\.d/[^/]+|usr/bin/chatgpt|usr/lib/chatgpt/(ChatGPT|codex-launcher|lib[^/]*\.so([.][0-9]+)*)|usr/share/applications/[^/]+\.desktop|usr/share/pixmaps/[^/]+)$' \
    "${data_list}" > "${critical_paths}" ||
    die 'Could not produce the critical package-path inventory.'

  info "Debian members: ${CONTROL_MEMBER}, ${DATA_MEMBER}"
  info 'Required executable, desktop file, icon, AppArmor profile, and shared libraries are present.'
}

write_upstream_metadata() {
  local output_dir=$1
  local control_file="${CONTROL_DIR}/control"
  local name
  local hash
  local -a hook_names=(config conffiles postinst postrm preinst prerm triggers)

  mkdir -p -- "${output_dir}"
  printf '%s\n' "${LATEST_VERSION}" > "${output_dir}/version"
  read_control_field 'Depends' "${control_file}" |
    sed 's/, /,\n/g' > "${output_dir}/depends"
  printf '%s\n%s\n' "${CONTROL_MEMBER}" "${DATA_MEMBER}" > "${output_dir}/archive-members"

  : > "${output_dir}/control-hooks.sha256"
  for name in "${hook_names[@]}"; do
    if [[ -f "${CONTROL_DIR}/${name}" ]]; then
      hash=$(sha256sum "${CONTROL_DIR}/${name}")
      printf '%s  %s\n' "${hash%% *}" "${name}" >> "${output_dir}/control-hooks.sha256"
    fi
  done

  cp -- "${WORK_DIR}/critical-paths" "${output_dir}/critical-paths"
}

show_file_change() {
  local label=$1
  local old_file=$2
  local new_file=$3

  if cmp -s "${old_file}" "${new_file}"; then
    info "${label}: unchanged"
    return 1
  fi

  warn "${label}: changed"
  diff -u --label "current/${label}" --label "latest/${label}" "${old_file}" "${new_file}" || true
  return 0
}

compare_upstream_metadata() {
  local baseline_version
  local latest_metadata="${WORK_DIR}/metadata"

  write_upstream_metadata "${latest_metadata}"

  if [[ ! -f "${METADATA_DIR}/version" ]]; then
    warn 'No upstream metadata baseline exists; dependency and maintainer-script changes cannot be compared.'
    INSTALL_REVIEW_NEEDED=1
    return
  fi

  baseline_version=$(<"${METADATA_DIR}/version")
  if [[ "${baseline_version}" != "${CURRENT_VERSION}" ]]; then
    warn "Metadata baseline ${baseline_version} does not match PKGBUILD ${CURRENT_VERSION}; change detection is incomplete."
    INSTALL_REVIEW_NEEDED=1
    return
  fi

  if show_file_change 'Debian Depends' "${METADATA_DIR}/depends" "${latest_metadata}/depends"; then
    DEPENDENCY_CHANGED=1
    warn 'Arch dependencies were not modified automatically; review and map every upstream change manually.'
  fi

  if show_file_change 'Debian control hooks' "${METADATA_DIR}/control-hooks.sha256" "${latest_metadata}/control-hooks.sha256"; then
    INSTALL_REVIEW_NEEDED=1
    warn 'chatgpt-bin.install may need changes; inspect the new maintainer scripts before publishing.'
  fi

  show_file_change 'Debian archive members' "${METADATA_DIR}/archive-members" "${latest_metadata}/archive-members" || true
  show_file_change 'Critical installed paths' "${METADATA_DIR}/critical-paths" "${latest_metadata}/critical-paths" || true

  if (( INSTALL_REVIEW_NEEDED == 0 )); then
    info 'chatgpt-bin.install impact: no maintainer-script or conffiles change detected.'
  fi
}

update_pkgbuild_copy() {
  local input=$1
  local output=$2
  local pkgver_count
  local pkgrel_count
  local checksum_count

  pkgver_count=$(grep -Ec '^pkgver=' "${input}")
  pkgrel_count=$(grep -Ec '^pkgrel=' "${input}")
  checksum_count=$(grep -Ec '^sha256sums=' "${input}")
  [[ "${pkgver_count}" == 1 && "${pkgrel_count}" == 1 && "${checksum_count}" == 1 ]] ||
    die 'PKGBUILD does not contain exactly one pkgver, pkgrel, and sha256sums assignment.'

  awk -v version="${LATEST_VERSION}" -v checksum="${LATEST_SHA256}" '
    /^pkgver=/ {
      print "pkgver=" version
      next
    }
    /^pkgrel=/ {
      print "pkgrel=1"
      next
    }
    /^sha256sums=/ {
      print "sha256sums=(\047" checksum "\047)"
      next
    }
    { print }
  ' "${input}" > "${output}"
}

build_candidate() {
  local candidate_pkgbuild="${WORK_DIR}/PKGBUILD"
  local build_dir="${WORK_DIR}/build"

  LATEST_SHA256=$(sha256sum "${DOWNLOADED_DEB}")
  LATEST_SHA256=${LATEST_SHA256%% *}
  info "SHA256: ${LATEST_SHA256}"

  update_pkgbuild_copy "${PKGBUILD_PATH}" "${candidate_pkgbuild}"

  info 'Proposed PKGBUILD diff before building:'
  diff -u --label 'PKGBUILD (current)' --label 'PKGBUILD (candidate)' \
    "${PKGBUILD_PATH}" "${candidate_pkgbuild}" || true

  mkdir -p -- "${build_dir}"
  cp -- "${candidate_pkgbuild}" "${build_dir}/PKGBUILD"
  cp -- "${INSTALL_PATH}" "${build_dir}/chatgpt-bin.install"
  ln "${DOWNLOADED_DEB}" "${build_dir}/${DEB_NAME}"

  # The separate data archive was only needed for inspection. Removing it keeps
  # temporary disk use bounded before makepkg extracts the deb again.
  rm -f -- "${DATA_ARCHIVE}"
  DATA_ARCHIVE=''

  info 'Running makepkg --cleanbuild (no sudo and no installation)'
  if ! (cd -- "${build_dir}" && makepkg --cleanbuild --force --noconfirm); then
    die 'makepkg failed. The repository PKGBUILD and existing deb were left unchanged.'
  fi
}

find_built_package() {
  local build_dir="${WORK_DIR}/build"
  local pkgrel
  local -a artifacts=()

  pkgrel=$(read_pkgbuild_value_from "${WORK_DIR}/PKGBUILD" 'pkgrel')
  while IFS= read -r artifact; do
    artifacts+=("${artifact}")
  done < <(find "${build_dir}" -maxdepth 1 -type f \
    -name "chatgpt-bin-${LATEST_VERSION}-${pkgrel}-x86_64.pkg.tar.*" -print)

  (( ${#artifacts[@]} == 1 )) ||
    die "Expected one built package archive, found ${#artifacts[@]}."
  printf '%s\n' "${artifacts[0]}"
}

read_pkgbuild_value_from() {
  local file=$1
  local key=$2
  awk -F= -v key="${key}" '$1 == key { value=$2; gsub(/[[:space:]'\''"]/, "", value); print value; exit }' "${file}"
}

verify_built_package() {
  local package_file=$1
  local package_list="${WORK_DIR}/built-package-files"
  local path
  local -a required_paths=(
    'etc/apparmor.d/chatgpt'
    'usr/bin/chatgpt'
    'usr/lib/chatgpt/ChatGPT'
    'usr/share/applications/chatgpt.desktop'
    'usr/share/pixmaps/chatgpt.png'
  )

  tar -tf "${package_file}" | sed -e 's#^\./##' -e 's#/$##' | sort -u > "${package_list}"
  for path in "${required_paths[@]}"; do
    grep -Fxq "${path}" "${package_list}" || die "Built package is missing /${path}."
  done
}

promote_results() {
  local package_file=$1
  local package_name
  local candidate_pkgbuild="${WORK_DIR}/PKGBUILD"
  local latest_metadata="${WORK_DIR}/metadata"
  local staged_deb="${SCRIPT_DIR}/.${DEB_NAME}.update-new"
  local staged_pkgbuild="${SCRIPT_DIR}/.PKGBUILD.update-new"
  local staged_package
  local metadata_file
  local staged_metadata="${SCRIPT_DIR}/.upstream-metadata.update-new"

  package_name=$(basename -- "${package_file}")
  staged_package="${SCRIPT_DIR}/.${package_name}.update-new"
  PROMOTION_STAGED=1

  cp -- "${DOWNLOADED_DEB}" "${staged_deb}"
  cp -- "${candidate_pkgbuild}" "${staged_pkgbuild}"
  cp -- "${package_file}" "${staged_package}"
  mkdir -p -- "${staged_metadata}"

  for metadata_file in version depends archive-members control-hooks.sha256 critical-paths; do
    cp -- "${latest_metadata}/${metadata_file}" "${staged_metadata}/${metadata_file}"
  done

  # PKGBUILD is moved last. If any staging copy fails, the current packaging
  # definition remains untouched and the cleanup trap removes only /tmp data.
  mv -f -- "${staged_deb}" "${SCRIPT_DIR}/${DEB_NAME}"
  mv -f -- "${staged_package}" "${SCRIPT_DIR}/${package_name}"
  mkdir -p -- "${METADATA_DIR}"
  cp -- "${staged_metadata}"/* "${METADATA_DIR}/"
  rm -rf -- "${staged_metadata}"
  mv -f -- "${staged_pkgbuild}" "${PKGBUILD_PATH}"
  PROMOTION_STAGED=0

  info "Build succeeded: ${package_name}"
  info 'Repository changes:'
  if command -v git >/dev/null 2>&1 && git -C "${SCRIPT_DIR}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "${SCRIPT_DIR}" status --short -- \
      PKGBUILD chatgpt-bin.install update.sh README.md upstream-metadata
    git -C "${SCRIPT_DIR}" diff -- \
      PKGBUILD chatgpt-bin.install update.sh README.md upstream-metadata || true
  else
    diff -u --label 'PKGBUILD (before)' --label 'PKGBUILD (after)' \
      "${WORK_DIR}/PKGBUILD.before" "${PKGBUILD_PATH}" || true
  fi

  if (( DEPENDENCY_CHANGED != 0 )); then
    warn 'Debian dependencies changed. Review the displayed metadata diff before publishing or installing.'
  fi
  if (( INSTALL_REVIEW_NEEDED != 0 )); then
    warn 'Maintainer-script metadata changed or could not be compared. Review chatgpt-bin.install.'
  fi

  printf '\nInstall only after reviewing the diff:\n'
  printf '  sudo pacman -U ./%s\n' "${package_name}"
}

main() {
  local package_file

  parse_args "$@"
  [[ -f "${PKGBUILD_PATH}" ]] || die "PKGBUILD not found in ${SCRIPT_DIR}."
  [[ -f "${INSTALL_PATH}" ]] || die "chatgpt-bin.install not found in ${SCRIPT_DIR}."
  require_commands

  CURRENT_VERSION=$(read_pkgbuild_value 'pkgver')
  [[ -n "${CURRENT_VERSION}" ]] || die 'Could not read pkgver from PKGBUILD.'

  WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/chatgpt-arch-update.XXXXXX")
  mkdir -p -- "${WORK_DIR}/metadata"
  cp -- "${PKGBUILD_PATH}" "${WORK_DIR}/PKGBUILD.before"

  download_latest_deb
  extract_control_metadata
  compare_versions
  extract_and_validate_data
  compare_upstream_metadata
  build_candidate
  package_file=$(find_built_package)
  verify_built_package "${package_file}"
  promote_results "${package_file}"
}

main "$@"
