# ========================================================
# Stage: Builder
# ========================================================
FROM golang:1.26-alpine AS builder
WORKDIR /app
ARG TARGETARCH

RUN apk --no-cache --update add \
  build-base \
  gcc \
  curl \
  unzip

COPY . .

ENV CGO_ENABLED=1
ENV CGO_CFLAGS="-D_LARGEFILE64_SOURCE"
RUN go build -ldflags "-w -s" -o build/x-ui main.go
RUN ./DockerInit.sh "$TARGETARCH"

# ========================================================
# Stage: Final Image of 3x-ui
# ========================================================
FROM alpine
ENV TZ=Asia/Tehran
WORKDIR /app

RUN apk add --no-cache --update \
  ca-certificates \
  tzdata \
  fail2ban \
  bash \
  curl \
  openssl

# 安装 cloudflared
ENV CLOUDFLARED_VERSION=2026.2.0
RUN curl -L -o /usr/local/bin/cloudflared https://github.com/cloudflare/cloudflared/releases/download/${CLOUDFLARED_VERSION}/cloudflared-linux-amd64 \
  && chmod +x /usr/local/bin/cloudflared

COPY --from=builder /app/build/ /app/
COPY --from=builder /app/DockerEntrypoint.sh /app/
COPY --from=builder /app/x-ui.sh /usr/bin/x-ui


# Configure fail2ban
RUN rm -f /etc/fail2ban/jail.d/alpine-ssh.conf \
  && cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local \
  && sed -i "s/^\[ssh\]$/&\nenabled = false/" /etc/fail2ban/jail.local \
  && sed -i "s/^\[sshd\]$/&\nenabled = false/" /etc/fail2ban/jail.local \
  && sed -i "s/#allowipv6 = auto/allowipv6 = auto/g" /etc/fail2ban/fail2ban.conf

RUN chmod +x \
  /app/DockerEntrypoint.sh \
  /app/x-ui \
  /usr/bin/x-ui
  /usr/local/bin/cloudflared

ENV XUI_ENABLE_FAIL2BAN="true"
EXPOSE 2053
VOLUME [ "/etc/x-ui" ]
COPY <<EOF /app/cloudflared-start.sh
#!/bin/sh
if [ -n "\$CLOUDFLARED_TOKEN" ]; then
  echo "Starting cloudflared tunnel..."
  cloudflared tunnel --no-autoupdate run --token "\$CLOUDFLARED_TOKEN" &
else
  echo "CLOUDFLARED_TOKEN not set, skipping cloudflared startup."
fi
exec "\$@"
EOF

RUN chmod +x /app/cloudflared-start.sh

# 替换 entrypoint，支持 cloudflared 启动
ENTRYPOINT [ "/app/cloudflared-start.sh", "/app/DockerEntrypoint.sh" ]
CMD [ "./x-ui" ]
