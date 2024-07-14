FROM debian:bullseye-slim as build-env
ENV DEBIAN_FRONTEND=noninteractive
ARG TESTS
ARG SOURCE_COMMIT
ARG BUSYBOX_VERSION=1.34.1
ARG SUPERVISOR_VERSION=4.2.4

RUN apt-get update && apt-get -y install \
    apt-utils \
    build-essential \
    curl \
    git \
    python3 \
    python3-pip \
    golang \
    shellcheck

# BusyBox Build
WORKDIR /build/busybox
RUN curl -L -o /tmp/busybox.tar.bz2 https://busybox.net/downloads/busybox-${BUSYBOX_VERSION}.tar.bz2 \
    && tar xjvf /tmp/busybox.tar.bz2 --strip-components=1 -C /build/busybox \
    && make defconfig \
    && sed -i -e "s/^CONFIG_FEATURE_SYSLOGD_READ_BUFFER_SIZE=.*/CONFIG_FEATURE_SYSLOGD_READ_BUFFER_SIZE=2048/" .config \
    && make \
    && cp busybox /usr/local/bin/

# Env2cfg Build
WORKDIR /build/env2cfg
COPY ./env2cfg/ /build/env2cfg/
RUN if [ "${TESTS:-true}" = true ]; then \
        pip3 install tox && tox; \
    fi
RUN python3 setup.py bdist --format=gztar

# Valheim Logfilter Build
WORKDIR /build/valheim-logfilter
COPY ./valheim-logfilter/ /build/valheim-logfilter/
RUN go build -ldflags="-s -w" \
    && mv valheim-logfilter /usr/local/bin/

# Python-a2s Build
WORKDIR /build
RUN git clone https://github.com/Yepoleb/python-a2s.git \
    && cd python-a2s \
    && python3 setup.py bdist --format=gztar

# Supervisor Build
WORKDIR /build/supervisor
RUN curl -L -o /tmp/supervisor.tar.gz https://github.com/Supervisor/supervisor/archive/${SUPERVISOR_VERSION}.tar.gz \
    && tar xzvf /tmp/supervisor.tar.gz --strip-components=1 -C /build/supervisor \
    && python3 setup.py bdist --format=gztar

# Copy Scripts and Configurations
COPY bootstrap /usr/local/sbin/
COPY valheim-* /usr/local/bin/
COPY defaults /usr/local/etc/valheim/
COPY common /usr/local/etc/valheim/
COPY contrib/* /usr/local/share/valheim/contrib/
RUN chmod 755 /usr/local/sbin/bootstrap /usr/local/bin/valheim-*

# ShellCheck Scripts
RUN if [ "${TESTS:-true}" = true ]; then \
        shellcheck -a -x -s bash -e SC2034 \
            /usr/local/sbin/bootstrap \
            /usr/local/bin/valheim-* \
            /usr/local/share/valheim/contrib/*.sh; \
    fi

# Extract Packages
WORKDIR /
RUN tar xzvf /build/supervisor/dist/supervisor-*.linux-aarch64.tar.gz \
    && tar xzvf /build/env2cfg/dist/env2cfg-*.linux-aarch64.tar.gz \
    && tar xzvf /build/python-a2s/dist/python-a2s-*.linux-aarch64.tar.gz

COPY supervisord.conf /usr/local/etc/supervisord.conf
RUN mkdir -p /usr/local/etc/supervisor/conf.d/ && chmod 640 /usr/local/etc/supervisord.conf
RUN echo "${SOURCE_COMMIT:-unknown}" > /usr/local/etc/git-commit.HEAD

FROM debian:buster-slim as libs
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get -y --no-install-recommends install \
    libc6-dev \
    libstdc++6 \
    libsdl2-2.0-0 \
    libcurl4 \
    libc6-i386 \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

FROM debian:bullseye-slim
ENV DEBIAN_FRONTEND=noninteractive

# Copy built files from build-env
COPY --from=build-env /usr/local/ /usr/local/
# Copy required libraries
COPY --from=libs /lib/ld-linux.so.2 /lib/ld-linux.so.2
COPY --from=libs /lib/i386-linux-gnu /lib/i386-linux-gnu
COPY --from=libs /usr/lib/i386-linux-gnu /usr/lib/i386-linux-gnu
COPY fake-supervisord /usr/bin/supervisord

# Install dependencies
RUN dpkg --add-architecture armhf \
    && apt-get update && apt-get install -y \
    curl \
    libc6:armhf \
    vim \
    git \
    cmake \
    python3 \
    gcc-arm-linux-gnueabihf

WORKDIR /root

# Install box86
RUN git clone https://github.com/ptitSeb/box86 --branch v0.3.6 \
    && cd box86 \
    && mkdir build && cd build \
    && cmake .. -DARM64=1 -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    && make -j$(nproc) \
    && make install

# Install box64
RUN git clone https://github.com/ptitSeb/box64 --branch v0.2.6 \
    && cd box64 \
    && mkdir build && cd build \
    && cmake .. -DARM_DYNAREC=ON -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    && make -j$(nproc) \
    && make install

# Clean up build process
RUN rm -rf /root/box64 /root/box86 \
    && apt-get autoremove --purge -y \
        curl \
        vim \
        git \
        cmake \
        python3 \
        gcc-arm-linux-gnueabihf

RUN groupadd -g "${PGID:-0}" -o valheim \
    && useradd -g "${PGID:-0}" -u "${PUID:-0}" -o --create-home valheim \
    && apt-get update && apt-get -y --no-install-recommends install \
        apt-utils \
        libc6-dev \
        libsdl2-2.0-0 \
        cron \
        curl \
        iproute2 \
        libcurl4 \
        ca-certificates \
        procps \
        locales \
        unzip \
        zip \
        rsync \
        openssh-client \
        jq \
        python3-minimal \
        python3-pkg-resources \
        python3-setuptools \
        libpulse-dev \
        libatomic1 \
        libc6 \
    && echo 'LANG="en_US.UTF-8"' > /etc/default/locale \
    && echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen \
    && rm -f /bin/sh && ln -s /bin/bash /bin/sh \
    && locale-gen \
    && update-alternatives --install /usr/bin/python python /usr/bin/python3 1 \
    && usermod -a -G crontab valheim \
    && apt-get clean \
    && mkdir -p /var/spool/cron/crontabs /var/log/supervisor /opt/valheim /opt/steamcmd /home/valheim/.config/unity3d/IronGate /config /var/run/valheim \
    && ln -s /config /home/valheim/.config/unity3d/IronGate/Valheim \
    && ln -s /usr/local/bin/busybox /usr/local/sbin/syslogd \
    && ln -s /usr/local/bin/busybox /usr/local/sbin/mkpasswd \
    && ln -s /usr/local/bin/busybox /usr/local/bin/vi \
    && ln -s /usr/local/bin/busybox /usr/local/bin/patch \
    && ln -s /usr/local/bin/busybox /usr/local/bin/unix2dos \
    && ln -s /usr/local/bin/busybox /usr/local/bin/dos2unix \
    && ln -s /usr/local/bin/busybox /usr/local/bin/makemime \
    && ln -s /usr/local/bin/busybox /usr/local/bin/xxd \
    && ln -s /usr/local/bin/busybox /usr/local/bin/wget \
    && ln -s /usr/local/bin/busybox /usr/local/bin/less \
    && ln -s /usr/local/bin/busybox /usr/local/bin/lsof \
    && ln -s /usr/local/bin/busybox /usr/local/bin/httpd \
    && ln -s /usr/local/bin/busybox /usr/local/bin/ssl_client \
    && ln -s /usr/local/bin/busybox /usr/local/bin/ip \
    && ln -s /usr/local/bin/busybox /usr/local/bin/ipcalc \
    && ln -s /usr/local/bin/busybox /usr/local/bin/ping \
    && ln -s /usr/local/bin/busybox /usr/local/bin/ping6 \
    && ln -s /usr/local/bin/busybox /usr/local/bin/iostat \
    && ln -s /usr/local/bin/busybox /usr/local/bin/setuidgid \
    && ln -s /usr/local/bin/busybox /usr/local/bin/ftpget \
    && ln -s /usr/local/bin/busybox /usr/local/bin/ftpput \
    && ln -s /usr/local/bin/busybox /usr/local/bin/bzip2 \
    && ln -s /usr/local/bin/busybox /usr/local/bin/xz \
    && ln -s /usr/local/bin/busybox /usr/local/bin/pstree \
    && ln -s /usr/local/bin/busybox /usr/local/bin/killall \
    && ln -s /usr/local/bin/busybox /usr/local/bin/bc \
    && curl -L -o /tmp/steamcmd_linux.tar.gz https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz \
    && tar xzvf /tmp/steamcmd_linux.tar.gz -C /opt/steamcmd/ \
    && chown valheim:valheim /var/run/valheim \
    && chown -R root:root /opt/steamcmd \
    && chmod 755 /opt/steamcmd/steamcmd.sh /opt/steamcmd/linux32/steamcmd /opt/steamcmd/linux32/steamerrorreporter /usr/bin/supervisord \
    && cd "/opt/steamcmd" \
    && su - valheim -c "/opt/steamcmd/steamcmd.sh +login anonymous +quit" \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* \
    && date --utc --iso-8601=seconds > /usr/local/etc/build.date

EXPOSE 2456-2457/udp
EXPOSE 9001/tcp
EXPOSE 80/tcp
WORKDIR /
CMD ["/usr/local/sbin/bootstrap"]
