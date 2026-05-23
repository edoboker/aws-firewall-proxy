# syntax=docker/dockerfile:1.7

# ---- Stage 1: compile the dynamic stream module against the matching vanilla nginx source ----
#
# OpenResty 1.27.1.1 bundles nginx 1.27.1. We build the .so against vanilla
# nginx-1.27.1 with --with-compat, which is the ABI-stability flag that makes
# the resulting module loadable by the OpenResty runtime (which is also built
# with --with-compat). We do NOT build against the OpenResty bundle here
# because OpenResty's top-level Makefile doesn't expose a `modules` target.
FROM alpine:3.20 AS builder

ARG NGINX_VERSION=1.27.1

RUN apk add --no-cache \
      build-base \
      pcre2-dev \
      openssl-dev \
      zlib-dev \
      linux-headers \
      perl \
      curl \
      tar

WORKDIR /build
RUN curl -fsSL "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz" -o nginx.tgz \
 && tar -xzf nginx.tgz \
 && rm nginx.tgz

COPY c-module/ /build/c-module/

WORKDIR /build/nginx-${NGINX_VERSION}
RUN ./configure \
      --with-stream \
      --with-stream_ssl_module \
      --with-stream_ssl_preread_module \
      --with-compat \
      --add-dynamic-module=/build/c-module \
 && make -j"$(nproc)" modules

RUN mkdir -p /out \
 && cp objs/ngx_stream_original_dst_module.so /out/


# ---- Stage 2: runtime ----
FROM openresty/openresty:1.27.1.1-alpine

RUN apk add --no-cache \
      iptables \
      ip6tables \
      curl \
      bind-tools \
      bash \
      openssl

# Drop the compiled module into OpenResty's modules dir and wire it via load_module.
COPY --from=builder /out/ngx_stream_original_dst_module.so \
     /usr/local/openresty/nginx/modules/ngx_stream_original_dst_module.so

COPY nginx.conf  /usr/local/openresty/nginx/conf/nginx.conf.template
COPY lua/        /usr/local/openresty/nginx/lua/
COPY entrypoint.sh /entrypoint.sh
COPY test/        /test/
RUN chmod +x /entrypoint.sh /test/spike.sh

# 8443 is the REDIRECT target. 443 is intercepted by iptables inside the container.
EXPOSE 443 8443

ENTRYPOINT ["/entrypoint.sh"]
