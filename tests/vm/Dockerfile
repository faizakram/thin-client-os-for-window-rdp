# Phase B test rig: an x86 PC with UEFI Secure Boot (Microsoft keys, like a real
# machine) and a TPM 2.0 — emulated, so nothing is installed on the host.
FROM debian:trixie
RUN apt-get update && apt-get install -y --no-install-recommends \
      qemu-system-x86 qemu-utils ovmf swtpm swtpm-tools \
      python3 imagemagick ca-certificates procps socat && \
    rm -rf /var/lib/apt/lists/*
