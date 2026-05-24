# Placeholder: SNI Spoofing Live Test

This document is a placeholder for the AWS integration test that should verify live SNI spoofing detection.

## Goal

From the workload EC2, send a TLS connection that:

- uses an allowed SNI such as `google.com`
- forces the TCP destination to a different IP with `curl --resolve`

The proxy should:

- reject the connection during preread
- emit a structured `WARN` line in the nginx error log
- preserve the Lua warning format used by `check_sni.lua`

## Desired assertions

- the workload-side command fails with connection reset or TLS failure
- the proxy error log contains `event="sni_spoofing_detected"`
- the warning includes `decision="mismatch"`
- the warning includes `sni="..."`
- the warning includes `original_dst="..."`
- the warning includes `dst_ip="..."`
- the warning includes `resolved="..."`
- the warning includes `dns_resolver="..."`

## Likely implementation path

- run the spoofed curl command on the workload via SSM
- fetch or query the proxy logs via CloudWatch Logs or SSM
- assert that the warning line appears within a short time window after the request
