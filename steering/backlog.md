1. Important limitation: stock open-source NGINX is not historically a full HTTP CONNECT forward proxy out of the box. Official HTTP CONNECT forward proxy support is documented for NGINX Plus R36+. Open-source deployments often use third-party CONNECT modules, Squid, Envoy, HAProxy, or egress-gateway patterns instead.
2. envoy vs nginx
3. subsequent dns tunnelling issue!