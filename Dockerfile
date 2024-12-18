ARG VERSION="4.9.1"


FROM hairyhenderson/gomplate:v3.11.5-slim AS gomplate



FROM wazuh/wazuh-manager:${VERSION} AS wazuh-manager
RUN find /var/ossec/ruleset/sca/ -name "*.yml" -exec mv {} {}.disabled \; \
  && mv /var/ossec/ruleset/sca /var/ossec/ruleset/sca.disabled



FROM golang:1.20.4-bullseye AS multirun
WORKDIR /src
RUN wget -c https://github.com/nicolas-van/multirun/releases/download/1.1.3/multirun-x86_64-linux-gnu-1.1.3.tar.gz -O - | tar -xz



FROM golang:1.20.4-bullseye AS fsnotify
WORKDIR /src
RUN git clone https://github.com/fsnotify/fsnotify .
RUN --mount=type=cache,target=/go/pkg/mod \
  --mount=type=cache,target=/root/.cache/go-build \
  cd cmd/fsnotify \
  && GOOS=linux go build -tags release -a -ldflags "-extldflags -static" -o fsnotify



FROM golang:1.20.4-bullseye AS job
WORKDIR /src
RUN git clone --depth 1 --branch v0.2.0 https://github.com/liujianping/job .
RUN --mount=type=cache,target=/go/pkg/mod \
  --mount=type=cache,target=/root/.cache/go-build \
  GOOS=linux go build -o job-


FROM debian:bullseye AS yara
RUN apt-get update -y && apt-get install -y \
  ca-certificates wget automake libtool make gcc pkg-config libjansson-dev libmagic-dev libssl-dev git
RUN cd /root && wget https://github.com/VirusTotal/yara/archive/refs/tags/v4.5.2.tar.gz \
  && tar -zxf v4.5.2.tar.gz \
  && cd yara-4.5.2 \
  && ./bootstrap.sh \
  && ./configure --prefix=/usr/local/yara --disable-dotnet --with-crypto --enable-magic --enable-cuckoo --disable-shared --enable-static\
  && make \
  && make install
RUN git clone https://github.com/Yara-Rules/rules && mv rules /usr/local/yara



FROM debian:bullseye AS wazuh-agent
ARG VERSION
ARG VERSION_REVISION="1"
RUN apt-get update -y && apt-get install -y \
  curl \
  apt-transport-https \
  gnupg2 \
  ca-certificates
RUN curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH | apt-key add - \
  && echo "deb https://packages.wazuh.com/4.x/apt/ stable main" | tee /etc/apt/sources.list.d/wazuh.list \
  && apt-get update -y && apt-get install -y wazuh-agent=${VERSION}-${VERSION_REVISION}



FROM golang AS wazuh-container-exec
WORKDIR /src
COPY wazuh-container-exec.go .
RUN --mount=type=cache,target=/go/pkg/mod \
  --mount=type=cache,target=/root/.cache/go-build \
  CGO_ENABLED=0 go build wazuh-container-exec.go


FROM python:3.11-slim-bullseye

RUN apt-get update -y && apt-get install -y \  
  rsync \
  libjansson4 \
  libmagic1 \
  libssl1.1 \
  curl \
  unzip \
  && rm -rf /var/cache/apt/lists

COPY --from=gomplate /gomplate /usr/bin/gomplate
COPY --from=multirun /src/multirun /usr/bin/multirun
COPY --from=job /src/job- /usr/bin/job
COPY --from=yara /usr/local/yara /usr/local/yara

COPY --from=wazuh-agent /var/ossec /var/ossec
COPY --from=wazuh-manager /var/ossec/ruleset/sca.disabled /var/ossec/ruleset/sca.disabled
COPY --from=fsnotify /src/cmd/fsnotify/fsnotify /var/ossec/bin/fsnotify
COPY --from=wazuh-container-exec /src/wazuh-container-exec /var/ossec/active-response/bin/wazuh-container-exec
COPY active-response/* /var/ossec/active-response/bin

COPY entrypoint.sh /entrypoint.sh 
COPY yara-rule-downloader.sh /yara-rule-downloader.sh
COPY wazuh-start.sh /var/ossec/bin/wazuh-start.sh
COPY wazuh-tail-logs.sh /var/ossec/bin/wazuh-tail-logs.sh
COPY ossec.tpl.conf /var/ossec/etc/ossec.tpl.conf

ENV WAZUH_MANAGER_ADDRESS="127.0.0.1"
ENV WAZUH_MANAGER_PORT="1514"
ENV WAZUH_MANAGER_ENROLLMENT_PORT="1515"
ENV WAZUH_AGENT_NAME="agent"
ENV WAZUH_AGENT_NAME_PREFIX=""
ENV WAZUH_AGENT_NAME_POSTFIX=""
ENV WAZUH_AGENT_HOST_DIR="/host"

ENTRYPOINT ["/entrypoint.sh"]
