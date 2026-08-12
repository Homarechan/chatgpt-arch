pkgname=chatgpt-bin
pkgver=26.803.81509
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
  'graphite'
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
  'openssl'
  'pango'
  'qt5-base'
  'qt6-base'
  'systemd-libs'
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
sha256sums=('a9bf91a368f9f7c4eea38082a9fb8fb46b8d005b719a6d7715d2e5a1982c38eb')

prepare() {
  cd "${srcdir}"
  ar x "${_deb}" control.tar.xz data.tar.xz
}

package() {
  tar --no-same-owner -xf "${srcdir}/data.tar.xz" -C "${pkgdir}"

  rm -rf "${pkgdir}/usr/share/lintian"
  install -Dm644 "${pkgdir}/usr/share/doc/chatgpt/copyright" \
    "${pkgdir}/usr/share/licenses/${pkgname}/copyright"
}
