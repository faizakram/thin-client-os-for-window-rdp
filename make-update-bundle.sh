#!/usr/bin/env bash
# =============================================================================
#  ThinClient OS — build & sign an OTA update bundle (run on the build host)
#
#  Usage:
#     ./make-update-bundle.sh 1.1.0                       # build + sign only
#     ./make-update-bundle.sh 1.1.0 --publish owner/repo  # + upload to a GitHub
#                                                          #   release (public repo)
#     ROLLOUT=25 ./make-update-bundle.sh 1.1.0 --publish owner/repo   # staged 25%
#
#  Produces dist/update-<ver>/{thinclient-<ver>.tar.gz, manifest, manifest.sig}.
#  Devices fetch these from  <UPDATE_URL>/{manifest,manifest.sig,<bundle>}  where
#  UPDATE_URL = https://github.com/owner/repo/releases/latest/download .
# =============================================================================
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
VER="${1:-}"
[[ -n "$VER" ]] || { echo "usage: $0 <version> [--publish owner/repo]"; exit 2; }
KEY="${ROOT}/update-signing-key.pem"
[[ -f "$KEY" ]] || { echo "signing key not found: $KEY"; exit 1; }

OUT="${ROOT}/dist/update-${VER}"
PAY="${OUT}/payload"
rm -rf "$OUT"
mkdir -p "${PAY}/bin" "${PAY}/lib" "${PAY}/share/openbox" "${PAY}/assets"

# Assemble EXACTLY the tree build.sh stages into /opt/thinclient.
cp "${ROOT}"/scripts/thinclient-* "${PAY}/bin/"
cp "${ROOT}"/scripts/lib/*.sh      "${PAY}/lib/"
cp "${ROOT}"/config/openbox/rc.xml.in       "${PAY}/share/openbox/" 2>/dev/null || true
cp "${ROOT}"/assets/branding/connecting.svg "${PAY}/assets/"        2>/dev/null || true
chmod +x "${PAY}/bin/"*
printf '%s\n' "$VER" > "${PAY}/VERSION"

bundle="thinclient-${VER}.tar.gz"
( cd "$PAY" && tar -czf "../${bundle}" . )

sha="$( (command -v sha256sum >/dev/null && sha256sum "${OUT}/${bundle}" || shasum -a 256 "${OUT}/${bundle}") | cut -d' ' -f1)"
cat > "${OUT}/manifest" <<EOF
version=${VER}
bundle=${bundle}
sha256=${sha}
rollout=${ROLLOUT:-100}
channel=${CHANNEL:-stable}
EOF

# --- Kernel for ENCRYPTED machines (thinclient-kernel; ignored by every other device) ---
#   TC_KERNEL_DIR=build-phaseb-<x>   a tools/phaseb/build-uki.sh output: its signed boot
#                                    image + the Debian kernel package are published WITH
#                                    this release and named, with hashes, in the manifest.
#   TC_KERNEL_CARRY=<old manifest>   no new kernel: carry the previous release's kernel
#                                    lines forward (a release without them only means
#                                    "nothing new" to a device, but carrying keeps a
#                                    machine that missed that release able to catch up).
# URLs are absolute (the assets stay in the release that published them, not "latest").
KERNEL_FILES=()
hashof() { (command -v sha256sum >/dev/null && sha256sum "$1" || shasum -a 256 "$1") | cut -d' ' -f1; }
if [[ -n "${TC_KERNEL_DIR:-}" ]]; then
  kver="$(cat "${TC_KERNEL_DIR}/KVER")"
  kimg="${TC_KERNEL_DIR}/thinclient-${kver}.efi"
  kpkg="$(ls "${TC_KERNEL_DIR}"/linux-image-"${kver}"_*.deb 2>/dev/null | head -1)"
  [[ -s "$kimg" && -s "$kpkg" ]] || { echo "TC_KERNEL_DIR needs thinclient-${kver}.efi and linux-image-${kver}_*.deb"; exit 1; }
  sbverify --cert "${ROOT}/keys/secureboot/MOK.crt" "$kimg" >/dev/null 2>&1 \
    || command -v sbverify >/dev/null || echo "  (sbverify not installed here — image signature not re-checked)"
  base=""; [[ "${2:-}" == "--publish" ]] && base="https://github.com/${3}/releases/download/v${VER}/"
  cp "$kimg" "${OUT}/"; cp "$kpkg" "${OUT}/"
  KERNEL_FILES=("${OUT}/$(basename "$kimg")" "${OUT}/$(basename "$kpkg")")
  cat >> "${OUT}/manifest" <<EOF
kernel_version=${kver}
kernel_image=${base}$(basename "$kimg")
kernel_image_sha256=$(hashof "$kimg")
kernel_pkg=${base}$(basename "$kpkg")
kernel_pkg_sha256=$(hashof "$kpkg")
EOF
elif [[ -n "${TC_KERNEL_CARRY:-}" ]]; then
  grep -E '^kernel_(version|image|image_sha256|pkg|pkg_sha256)=' "$TC_KERNEL_CARRY" >> "${OUT}/manifest" || true
fi
openssl dgst -sha256 -sign "$KEY" -out "${OUT}/manifest.sig" "${OUT}/manifest"

echo "Built + signed:"
echo "  ${OUT}/${bundle}"
echo "  ${OUT}/manifest       (version=${VER}, sha256=${sha:0:16}…, rollout=${ROLLOUT:-100}%)"
echo "  ${OUT}/manifest.sig"

if [[ "${2:-}" == "--publish" ]]; then
  repo="${3:?repo required: owner/repo}"
  command -v gh >/dev/null || { echo "gh CLI not installed"; exit 1; }
  gh release create "v${VER}" -R "$repo" -t "v${VER}" -n "ThinClient update ${VER}" \
     "${OUT}/${bundle}" "${OUT}/manifest" "${OUT}/manifest.sig" "${KERNEL_FILES[@]}" 2>/dev/null \
  || gh release upload "v${VER}" -R "$repo" --clobber \
     "${OUT}/${bundle}" "${OUT}/manifest" "${OUT}/manifest.sig" "${KERNEL_FILES[@]}"
  echo "Published -> https://github.com/${repo}/releases/tag/v${VER}"
  echo "Set on devices:  UPDATE_URL=https://github.com/${repo}/releases/latest/download"
fi
