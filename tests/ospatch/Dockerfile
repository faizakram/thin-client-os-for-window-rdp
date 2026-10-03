FROM debian:trixie
# Like a device built a while ago: packages from the main archive only, NO security fixes.
# docker-clean deletes downloaded .debs after every install; devices keep them.
RUN rm -f /etc/apt/apt.conf.d/docker-clean /etc/apt/sources.list.d/* /etc/apt/sources.list && \
    echo 'deb http://deb.debian.org/debian trixie main' > /etc/apt/sources.list && \
    apt-get update && apt-get install -y --no-install-recommends freerdp3-x11 python3 openssl ca-certificates util-linux && \
    rm -rf /var/lib/apt/lists/*
