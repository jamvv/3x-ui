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
# Stage: Final Image of 3x-ui with Cloudflared
# ========================================================
FROM alpine
ENV TZ=Asia/Tehran
WORKDIR /app
# 必须重新声明 ARG 才能在当前阶段使用
ARG TARGETARCH

# 合并了新版的依赖包 (openssl) 和运行 cloudflared 必须的包
RUN apk add --no-cache --update \
  ca-certificates \
  tzdata \
  fail2ban \
  bash \
  curl \
  openssl

# ==========================================
# 迁移功能：安装 Cloudflared
# ==========================================
# 自动根据构建架构下载对应版本 (amd64, arm64, arm, 386)
# 替换了老版本硬编码 amd64 的问题，以支持多架构构建
RUN curl -L -o /usr/local/bin/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${TARGETARCH} \
  && chmod +x /usr/local/bin/cloudflared

COPY --from=builder /app/build/ /app/
COPY --from=builder /app/DockerEntrypoint.sh /app/
COPY --from=builder /app/x-ui.sh /usr/bin/x-ui

# 配置 fail2ban
RUN rm -f /etc/fail2ban/jail.d/alpine-ssh.conf \
  && cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local \
  && sed -i "s/^\[ssh\]$/&\nenabled = false/" /etc/fail2ban/jail.local \
  && sed -i "s/^\[sshd\]$/&\nenabled = false/" /etc/fail2ban/jail.local \
  && sed -i "s/#allowipv6 = auto/allowipv6 = auto/g" /etc/fail2ban/fail2ban.conf

# ==========================================
# 迁移功能：Cloudflared 启动脚本
# ==========================================
COPY <<EOF /app/cloudflared-start.sh
#!/bin/sh
if [ -n "\$CLOUDFLARED_TOKEN" ]; then
  echo "Starting cloudflared tunnel..."
  # 以后台模式运行，避免阻塞主进程
  cloudflared tunnel --no-autoupdate run --token "\$CLOUDFLARED_TOKEN" &
else
  echo "CLOUDFLARED_TOKEN not set, skipping cloudflared startup."
fi
# 执行下一个命令 (DockerEntrypoint.sh)
exec "\$@"
EOF

# 设置权限
RUN chmod +x \
  /app/DockerEntrypoint.sh \
  /app/x-ui \
  /usr/bin/x-ui \
  /app/cloudflared-start.sh

ENV XUI_ENABLE_FAIL2BAN="true"
EXPOSE 2053
VOLUME [ "/etc/x-ui" ]

# CMD 保持不变
CMD [ "./x-ui" ]

# ==========================================
# 迁移功能：修改入口点
# ==========================================
# 优先执行 cloudflared-start.sh，它会启动隧道并 exec 传递给 DockerEntrypoint.sh
ENTRYPOINT [ "/app/cloudflared-start.sh", "/app/DockerEntrypoint.sh" ]
