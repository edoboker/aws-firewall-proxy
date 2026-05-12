# ── Envoy Proxy — EC2 in the proxy subnet ────────────────────────────────────
# Route table wiring is done manually — this file only provisions the instance.

resource "aws_security_group" "envoy" {
  name        = "${local.name}-envoy-sg"
  description = "Envoy proxy EC2 - transparent TLS proxy"
  vpc_id      = aws_vpc.main.id

  # SG is evaluated before iptables REDIRECT, so allow TCP 443 (not 8443) from workload
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.workload_subnet_cidr]
  }

  ingress {
    description     = "SSH from EC2 Instance Connect Endpoint"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.eic_endpoint.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "envoy" {
  ami                    = data.aws_ssm_parameter.al2023_ami.value
  instance_type          = var.envoy_instance_type
  subnet_id              = aws_subnet.proxy.id
  vpc_security_group_ids = [aws_security_group.envoy.id]
  source_dest_check      = false

  user_data_base64 = base64encode(<<-EOF
    #!/bin/bash
    set -e

    # IP forwarding required for transparent proxy
    echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.d/99-proxy.conf
    sysctl -p /etc/sysctl.d/99-proxy.conf

    # Install envoy
    dnf install -y curl
    ENVOY_VERSION="1.32.2"
    curl -fL -o /usr/local/bin/envoy \
      "https://github.com/envoyproxy/envoy/releases/download/v$${ENVOY_VERSION}/envoy-$${ENVOY_VERSION}-linux-x86_64"
    chmod +x /usr/local/bin/envoy

    mkdir -p /etc/envoy /var/log/envoy

    cat > /etc/envoy/envoy.yaml << 'ENVOYCONF'
static_resources:
  listeners:
  - name: tls_sni_rebind_listener
    address:
      socket_address:
        address: 0.0.0.0
        port_value: 8443

    listener_filters:
    - name: envoy.filters.listener.original_dst
      typed_config:
        "@type": type.googleapis.com/envoy.extensions.filters.listener.original_dst.v3.OriginalDst

    - name: envoy.filters.listener.tls_inspector
      typed_config:
        "@type": type.googleapis.com/envoy.extensions.filters.listener.tls_inspector.v3.TlsInspector

    filter_chains:
    - filters:
      - name: envoy.filters.network.sni_dynamic_forward_proxy
        typed_config:
          "@type": type.googleapis.com/envoy.extensions.filters.network.sni_dynamic_forward_proxy.v3.FilterConfig
          port_value: 443
          dns_cache_config:
            name: sni_dns_cache
            dns_lookup_family: V4_ONLY
            typed_dns_resolver_config:
              name: envoy.network.dns_resolver.cares
              typed_config:
                "@type": type.googleapis.com/envoy.extensions.network.dns_resolver.cares.v3.CaresDnsResolverConfig
                resolvers:
                - socket_address:
                    address: 169.254.169.253
                    port_value: 53

      - name: envoy.filters.network.tcp_proxy
        typed_config:
          "@type": type.googleapis.com/envoy.extensions.filters.network.tcp_proxy.v3.TcpProxy
          stat_prefix: sni_tcp_proxy
          cluster: sni_dynamic_forward_proxy_cluster
          access_log:
          - name: envoy.access_loggers.file
            typed_config:
              "@type": type.googleapis.com/envoy.extensions.access_loggers.file.v3.FileAccessLog
              path: /var/log/envoy/sni-egress.log
              log_format:
                text_format: >
                  downstream=%DOWNSTREAM_REMOTE_ADDRESS%
                  local=%DOWNSTREAM_LOCAL_ADDRESS%
                  requested_sni=%REQUESTED_SERVER_NAME%
                  upstream=%UPSTREAM_REMOTE_ADDRESS%
                  upstream_host=%UPSTREAM_HOST%
                  response_flags=%RESPONSE_FLAGS%
                  bytes_rx=%BYTES_RECEIVED%
                  bytes_tx=%BYTES_SENT%
                  duration_ms=%DURATION%
                  start=%START_TIME%
                  \n

  clusters:
  - name: sni_dynamic_forward_proxy_cluster
    lb_policy: CLUSTER_PROVIDED
    cluster_type:
      name: envoy.clusters.dynamic_forward_proxy
      typed_config:
        "@type": type.googleapis.com/envoy.extensions.clusters.dynamic_forward_proxy.v3.ClusterConfig
        dns_cache_config:
          name: sni_dns_cache
          dns_lookup_family: V4_ONLY
          typed_dns_resolver_config:
            name: envoy.network.dns_resolver.cares
            typed_config:
              "@type": type.googleapis.com/envoy.extensions.network.dns_resolver.cares.v3.CaresDnsResolverConfig
              resolvers:
              - socket_address:
                  address: 169.254.169.253
                  port_value: 53

admin:
  address:
    socket_address:
      address: 127.0.0.1
      port_value: 9901
ENVOYCONF

    # Dedicated user so iptables OUTPUT exception can match by UID
    useradd -r -s /sbin/nologin envoy
    chown -R envoy:envoy /etc/envoy /var/log/envoy

    # systemd service
    cat > /etc/systemd/system/envoy.service << 'SERVICE'
[Unit]
Description=Envoy Proxy
After=network.target

[Service]
User=envoy
ExecStart=/usr/local/bin/envoy -c /etc/envoy/envoy.yaml
Restart=on-failure

[Install]
WantedBy=multi-user.target
SERVICE

    # iptables: redirect inbound TCP:443 to envoy, exclude envoy's own outbound
    ENVOY_UID=$(id -u envoy)
    iptables -t nat -A PREROUTING -p tcp --dport 443 -j REDIRECT --to-port 8443
    iptables -t nat -A OUTPUT -p tcp --dport 443 -m owner --uid-owner $ENVOY_UID -j RETURN

    systemctl daemon-reload
    systemctl enable envoy
    systemctl start envoy
  EOF
  )

  tags = { Name = "${local.name}-envoy-proxy-ec2" }
}
