# Placeholder: SNI Spoofing Live Test

This document is a placeholder for the AWS integration test that should verify live SNI spoofing detection.

## Goal

From the workload EC2, send a TLS connection that:

- uses an allowed SNI such as `google.com`
- forces the TCP destination to a different IP with `curl --resolve`

The proxy should:

- reject the connection during preread
- emit a structured line in the dedicated SNI-spoofing log (`/var/log/nginx/sni_spoofing.log` → CloudWatch group `/aws/firewall-proxy/nginx/sni-spoofing`), **not** the error log

## Desired assertions

- the workload-side command fails with connection reset or TLS failure
- a line appears in the `/aws/firewall-proxy/nginx/sni-spoofing` group (sni_spoofing_log_format)
- the line includes `decision="mismatch"`
- the line includes `sni="..."`
- the line includes `original_dst="..."`
- the line includes `dst_ip="..."`
- the line includes `resolved="..."`
- the `SpoofingDetected` metric (`AwsFirewallProxy/Nginx`) increments
- the nginx error log contains **no** spoofing line

## Likely implementation path

- run the spoofed curl command on the workload via SSM
- fetch or query the `/aws/firewall-proxy/nginx/sni-spoofing` group via CloudWatch Logs or SSM
- assert that the spoofing line appears within a short time window after the request
