FROM debian:13-slim
# python3-cairo + python3-gi-cairo matter: without them the lock falls back to a flat
# tile and the Cairo bubble - the path that actually runs on a device - goes untested.
RUN apt-get update && apt-get install -y --no-install-recommends \
      python3 python3-gi python3-cairo python3-gi-cairo gir1.2-gtk-3.0 xvfb dbus-x11 \
    && rm -rf /var/lib/apt/lists/*
