#!/bin/bash
# dist/linux/appimage.sh  --  patched for modern runner images
# Changes vs upstream:
#   * compat-library copy is best-effort and version-agnostic (libffi.so.7 is
#     gone on 22.04+, libpcre.so.3 and libsepol.so.1 are gone on 24.04+).
#     Under `bash -e` the original unguarded cp aborted the whole job.
#   * the libwayland-client removal is guarded (rm -f).
#   * tool downloads are checked instead of silently producing a 0-byte file.
#   * UPD_INFO is overridable so a fork does not advertise upstream's
#     zsync update channel.

set -uo pipefail

if [[ -z "${GITHUB_WORKSPACE:-}" ]]; then
	export GITHUB_WORKSPACE="."
fi

die() { echo "::error::$*" >&2; exit 1; }

# ---------------------------------------------------------------- tooling ---
curl -sSfLO "https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage" \
	|| die "failed to download linuxdeploy"
chmod a+x linuxdeploy-x86_64.AppImage

MKAI_PATH="$(curl -sSfL https://github.com/probonopd/go-appimage/releases/expanded_assets/continuous \
	| grep "mkappimage-.*-x86_64.AppImage" | head -n 1 | cut -d '"' -f 2)"
[[ -n "${MKAI_PATH}" ]] || die "could not resolve a mkappimage download URL"
curl -sSfL "https://github.com${MKAI_PATH}" -o mkappimage.AppImage || die "failed to download mkappimage"
chmod a+x mkappimage.AppImage

curl -sSfLO "https://raw.githubusercontent.com/linuxdeploy/linuxdeploy-plugin-gtk/master/linuxdeploy-plugin-gtk.sh" \
	|| die "failed to download linuxdeploy-plugin-gtk"
chmod a+x linuxdeploy-plugin-gtk.sh

curl -sSfLO "https://github.com/darealshinji/linuxdeploy-plugin-checkrt/releases/download/continuous/linuxdeploy-plugin-checkrt.sh" \
	|| die "failed to download linuxdeploy-plugin-checkrt"
chmod a+x linuxdeploy-plugin-checkrt.sh

if [[ ! -e /usr/lib/x86_64-linux-gnu ]]; then
	sed -i 's#lib\/x86_64-linux-gnu#lib64#g' linuxdeploy-plugin-gtk.sh
fi

# ---------------------------------------------------------------- appdir ----
mkdir -p AppDir/usr/bin
mkdir -p AppDir/usr/share/Cemu
mkdir -p AppDir/usr/share/applications
mkdir -p AppDir/usr/share/icons/hicolor/128x128/apps
mkdir -p AppDir/usr/share/metainfo
mkdir -p AppDir/usr/lib

cp dist/linux/info.cemu.Cemu.{desktop,png} AppDir/
cp dist/linux/info.cemu.Cemu.metainfo.xml AppDir/usr/share/metainfo/info.cemu.Cemu.appdata.xml

cp -r bin/* AppDir/usr/share/Cemu
mv AppDir/usr/share/Cemu/Cemu AppDir/usr/bin/
chmod +x AppDir/usr/bin/Cemu

# ------------------------------------------------- compat libs (optional) ---
# These exist to keep the AppImage usable on older glibc hosts. Any that the
# build image does not ship are simply skipped -- none of them are required.
LIB_SEARCH_DIRS=(/usr/lib/x86_64-linux-gnu /usr/lib64 /lib/x86_64-linux-gnu)
COMPAT_LIBS=(
	"libsepol.so.*"
	"libffi.so.*"
	"libpcre.so.*"
	"libpcre2-8.so.*"
	"libGLU.so.*"
	"libthai.so.*"
)
for pattern in "${COMPAT_LIBS[@]}"; do
	found=0
	for dir in "${LIB_SEARCH_DIRS[@]}"; do
		[[ -d "${dir}" ]] || continue
		for lib in "${dir}"/${pattern}; do
			[[ -f "${lib}" ]] || continue
			cp -n "${lib}" AppDir/usr/lib/ && found=1
		done
	done
	[[ ${found} -eq 1 ]] || echo "note: no match for ${pattern}, skipping"
done

# ---------------------------------------------------------------- build -----
# Override in CI if you want your fork to serve updates; empty = no channel.
export UPD_INFO="${UPD_INFO:-}"
export NO_STRIP=1

./linuxdeploy-x86_64.AppImage --appimage-extract-and-run \
	--appdir="${GITHUB_WORKSPACE}"/AppDir/ \
	-d "${GITHUB_WORKSPACE}"/AppDir/info.cemu.Cemu.desktop \
	-i "${GITHUB_WORKSPACE}"/AppDir/info.cemu.Cemu.png \
	-e "${GITHUB_WORKSPACE}"/AppDir/usr/bin/Cemu \
	--plugin gtk \
	--plugin checkrt \
	|| die "linuxdeploy failed"

if ! GITVERSION="$(git rev-parse --short HEAD 2>/dev/null)"; then
	GITVERSION=experimental
fi
echo "Cemu Version Cemu-${GITVERSION}"

# The bundled wayland client conflicts with the host compositor's copy.
rm -f AppDir/usr/lib/libwayland-client.so.0

if [[ -f AppDir/apprun-hooks/linuxdeploy-plugin-gtk.sh ]]; then
	printf 'export LC_ALL=C\nexport FONTCONFIG_PATH=/etc/fonts\n' \
		>> AppDir/apprun-hooks/linuxdeploy-plugin-gtk.sh
else
	echo "::warning::gtk apprun hook missing -- locale/fontconfig exports skipped"
fi

VERSION="${GITVERSION}" ./mkappimage.AppImage --appimage-extract-and-run "${GITHUB_WORKSPACE}"/AppDir \
	|| die "mkappimage failed"

mkdir -p "${GITHUB_WORKSPACE}"/artifacts/
mv Cemu-"${GITVERSION}"-x86_64.AppImage "${GITHUB_WORKSPACE}"/artifacts/
echo "AppImage written to artifacts/Cemu-${GITVERSION}-x86_64.AppImage"
