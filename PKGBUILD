pkgname=chatgpt-bin
pkgver=26.901.51231
pkgrel=1
pkgdesc='ChatGPT by OpenAI'
arch=('x86_64')
url='https://developers.openai.com/codex/app'
license=('custom')
depends=(
  'alsa-lib'
  'at-spi2-core'
  'cairo'
  'dbus'
  'desktop-file-utils'
  'expat'
  'gdk-pixbuf2'
  'glib2'
  'glibc'
  'gtk3'
  'libcups'
  'libdrm'
  'libgcc'
  'libglvnd'
  'libnotify'
  'libstdc++'
  'libusb'
  'libx11'
  'libxcb'
  'libxcomposite'
  'libxdamage'
  'libxext'
  'libxfixes'
  'libxkbcommon'
  'libxrandr'
  'mesa'
  'nspr'
  'nss'
  'pango'
  'qt5-base'
  'qt6-base'
  'systemd-libs'
  'vulkan-driver'
  'xdg-utils'
  'xz'
)
optdepends=(
  'apparmor: load the included AppArmor profile'
  'git: recommended by the upstream Debian package'
  'gnome-keyring: secret storage integration'
  'libsecret: desktop secret service integration'
  'lsb-release: distribution detection for bundled tools'
  'pipewire-pulse: PulseAudio-compatible audio backend'
  'pulseaudio: PulseAudio audio backend'
)
provides=('chatgpt')
conflicts=('chatgpt')
backup=('etc/apparmor.d/chatgpt')
install='chatgpt-bin.install'
options=('!strip' '!debug')
_deb='chatgpt_amd64.deb'
source=("${_deb}")
noextract=("${_deb}")
sha256sums=('62580188d87c3d3a9369dab7c73b42a8a32518d4df8a2d5bae6466ddeac5c05e')

prepare() {
  cd "${srcdir}"

  local -a data_members=()
  mapfile -t data_members < <(ar t "${_deb}" | sed -n '/^data\.tar\($\|\.\)/p')
  if (( ${#data_members[@]} != 1 )); then
    error "Expected exactly one data.tar.*, found ${#data_members[@]}"
    return 1
  fi

  ar x "${_deb}" "${data_members[0]}"
  printf '%s\n' "${data_members[0]}" > .data-member
}

package() {
  local data_member
  data_member=$(<"${srcdir}/.data-member")
  tar --no-same-owner -xf "${srcdir}/${data_member}" -C "${pkgdir}"

  rm -rf "${pkgdir}/usr/share/lintian"
  install -Dm644 "${pkgdir}/usr/share/doc/chatgpt/copyright" \
    "${pkgdir}/usr/share/licenses/${pkgname}/copyright"
}
