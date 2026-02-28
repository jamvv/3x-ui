# ========================================================
# Stage: Builder (构建阶段)
# ========================================================
# 保持你新版本提供的 Go 版本
FROM golang:1.26-alpine AS builder
WORKDIR /app

# 虽然指定 AMD64，但保留这个 ARG 确保脚本兼容性
ARG TARGETARCH

RUN apk --no-cache --update add \
  build-base \
  gcc \
  curl \
  unzip

COPY . .

ENV CGO_ENABLED=1
ENV CGO_CFLAGS="-D_LARGEFILE64_SOURCE"

# 编译主程序
RUN go build -ldflags "-w -s" -o build/x-ui main.go
# 运行初始化脚本
RUN ./DockerInit.sh "$TARGETARCH"

# ========================================================
# Stage: Final Image (最终镜像 - AMD64)
# ========================================================
FROM alpine
ENV TZ=Asia/Tehran
WORKDIR /app

# 1. 安装依赖
# - 新版依赖: ca-certificates, tzdata, fail2ban, bash, curl, openssl
# - Cloudflared兼容依赖: libc6-compat, gcompat (Alpine 运行 AMD64 程序必须)
RUN apk add --no-cache --update \
  ca-certificates \
  tzdata \
  fail2ban \
  bash \
  curl \
  openssl \
  libc6-compat \
  gcompat

# 2. 安装 Cloudflared (强制指定 AMD64 版本)
# 这里直接拉取官方最新的 amd64 版本
RUN curl -L -o /usr/local/bin/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
  && chmod +x /usr/local/bin/cloudflared

# 3. 复制构建产物
COPY --from=builder /app/build/ /app/
COPY --from=builder /app/DockerEntrypoint.sh /app/
COPY --from=builder /app/x-ui.sh /usr/bin/x-ui

# 4. 配置 fail2ban (新版逻辑)
RUN rm -f /etc/fail2ban/jail.d/alpine-ssh.conf \
  && cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local \
  && sed -i "s/^\[ssh\]$/&\nenabled = false/" /etc/fail2ban/jail.local \
  && sed -i "s/^\[sshd\]$/&\nenabled = false/" /etc/fail2ban/jail.local \
  && sed -i "s/#allowipv6 = auto/allowipv6 = auto/g" /etc/fail2ban/fail2ban.conf

# 5. 生成 Cloudflared 启动脚本 (老版功能迁移)
# 作用：如果存在 Token，后台启动隧道；否则跳过
RUN printf '#!/bin/sh\n\
if [ -n "$CLOUDFLARED_TOKEN" ]; then\n\
  echo "Starting cloudflared tunnel (AMD64)..."\n\
  cloudflared tunnel --no-autoupdate run --token "$CLOUDFLARED_TOKEN" &\n\
else\n\
  echo "CLOUDFLARED_TOKEN not set, skipping cloudflared startup."\n\
fi\n\
exec "$@"\n' > /app/cloudflared-start.sh

# 6. 设置权限
RUN chmod +x \
  /app/DockerEntrypoint.sh \
  /app/x-ui \
  /usr/bin/x-ui \
  /app/cloudflared-start.sh

ENV XUI_ENABLE_FAIL2BAN="true"
EXPOSE 2053
VOLUME [ "/etc/x-ui" ]

CMD [ "./x-ui" ]

# 7. 设置入口点
# 先执行 cloudflared-start.sh (处理隧道)，再执行 DockerEntrypoint.sh (初始化 x-ui)
ENTRYPOINT [ "/app/cloudflared-start.sh", "/app/DockerEntrypoint.sh" ]
