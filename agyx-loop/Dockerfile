# Loop autônomo do agyx-next em container: Debian mínimo + systemd + pi (NVIDIA NIM).
# O repositório do agyx-next é montado no MESMO caminho do host para que os
# worktrees do git e o estado do loop (loop/state, loop/var) continuem válidos
# dos dois lados. A chave da NVIDIA nunca entra na imagem: vem de um env file montado.
#
# Build:  ./agyxd build
# Sobe:   ./agyxd up
FROM debian:trixie-slim

ARG GO_VERSION=1.27.0
ARG NODE_MAJOR=24
ARG PI_VERSION=1.2.0
ARG JUST_VERSION=1.42.4
ENV DEBIAN_FRONTEND=noninteractive TZ=America/Bahia

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl git python3 bubblewrap ripgrep jq tzdata procps xz-utils \
      systemd systemd-sysv \
 && rm -rf /var/lib/apt/lists/*

# just — binário estático (mesma versão do host)
RUN curl -fsSL "https://github.com/casey/just/releases/download/${JUST_VERSION}/just-${JUST_VERSION}-x86_64-unknown-linux-musl.tar.gz" \
      | tar -xz -C /usr/local/bin just

# Go — mesma série do host para reaproveitar o cache de build montado
RUN curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" | tar -xz -C /usr/local
ENV PATH="/usr/local/go/bin:${PATH}"

# Node + pi (agente CLI; provider NVIDIA NIM embutido, complementado por pi-models.json)
ARG NODE_VERSION=24.11.1
RUN curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" \
      | tar -xJ -C /usr/local --strip-components=1 \
 && npm install -g --ignore-scripts "@earendil-works/pi-coding-agent@${PI_VERSION}" \
 && npm cache clean --force

# Usuário do serviço — mesmo UID do dono do repositório no host (1000)
RUN useradd -m -u 1000 -s /bin/bash agent

# Overlay de modelos NVIDIA NIM para o pi (a chave vem por env; nada de segredo na imagem)
COPY pi-models.json /home/agent/.pi/agent/models.json
RUN chown -R agent:agent /home/agent && chmod 600 /home/agent/.pi/agent/models.json

# Ponto de montagem do repositório (mesmo caminho do host)
RUN mkdir -p /home/sh-lucas/Github/rox-projects/agyx

COPY agyx-loop.service /etc/systemd/system/agyx-loop.service
RUN systemctl enable agyx-loop.service \
 && systemctl mask systemd-udevd.service systemd-modules-load.service

STOPSIGNAL SIGRTMIN+3
CMD ["/lib/systemd/systemd"]
