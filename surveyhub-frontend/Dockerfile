# syntax=docker/dockerfile:1.7
#
# next.config.ts sets `output: "export"`, so `next build` emits a static site to ./out —
# there is no .next/standalone and no server.js. The previous Dockerfile copied both and
# ran `node server.js`, so the image could never start. It also expected a bun.lockb that
# does not exist in this repo; only package-lock.json is committed.
#
# This builds the static export and serves it from nginx, which is how the app is
# actually deployed (Cloudflare Pages), so local and production now behave the same.

# ---------------------------------------------------------------------------- builder
FROM node:20-alpine AS builder
WORKDIR /app

COPY package.json package-lock.json ./
RUN --mount=type=cache,target=/root/.npm npm ci

COPY . .

# Baked in at build time — a static export cannot read env vars at runtime.
ARG NEXT_PUBLIC_API_URL=http://localhost:8000
ENV NEXT_PUBLIC_API_URL=${NEXT_PUBLIC_API_URL} \
    NEXT_TELEMETRY_DISABLED=1

RUN npm run build

# ---------------------------------------------------------------------------- runtime
FROM nginx:1.31-alpine AS runtime

RUN rm -rf /usr/share/nginx/html/* /etc/nginx/conf.d/default.conf

COPY --from=builder /app/out /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/app.conf

# nginx:alpine ships an unprivileged `nginx` user; give it the paths it needs so the
# container never runs as root.
RUN touch /var/run/nginx.pid \
    && chown -R nginx:nginx /var/run/nginx.pid /var/cache/nginx /usr/share/nginx/html

USER nginx
EXPOSE 8080

# --proxy=off because some daemons inject HTTP_PROXY into every container and busybox
# wget ignores NO_PROXY, so a loopback probe gets routed to the proxy and returns 503.
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD wget --proxy=off -qO- http://127.0.0.1:8080/healthz >/dev/null 2>&1 || exit 1

CMD ["nginx", "-g", "daemon off;"]
