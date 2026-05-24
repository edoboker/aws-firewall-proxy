What to send continuously
Always-on metrics

Publish aggregated metrics every 60 seconds:

RequestsPerSecond
ActiveConnections
AcceptedConnections
BlockedConnections
SniMismatchCount
DnsResolutionFailureCount
UpstreamConnectFailureCount
P50/P95/P99ProxyDecisionLatencyMs
P50/P95/P99UpstreamConnectLatencyMs
CPUUtilization
MemoryUtilization
NetworkIn/Out

Metrics are much cheaper and more useful for dashboards and alarms than shipping every connection as a log line.

Important: keep dimensions low-cardinality.

Good dimensions:

InstanceId
AutoScalingGroup
AvailabilityZone
Decision=allow|block
Reason=sni_mismatch|dns_failure|allowlist_denied

Bad dimensions:

SNI
SourceIP
DestinationIP
ResolvedIP
RequestId

Do not put high-cardinality values into CloudWatch metric dimensions.

What to log continuously
Sparse structured logs only

Send:

nginx error.log
security-events.log
proxy-startup/config-load events

For security events, log only when something meaningful happens:

SNI mismatch
blocked FQDN
DNS failure under fail-closed policy
original_dst unavailable
Lua/plugin internal error
policy config failed to load

What not to log continuously

Do not ship this per connection by default:

every allowed SNI
every resolved IP
every original_dst
every connect time
every successful proxy decision
every DNS answer

That becomes expensive fast and produces low-value telemetry.

How to measure latency without per-connection logs

Have the proxy aggregate internally and publish percentiles periodically.

For example, every 60 seconds emit:

proxy_decision_latency_ms p50/p95/p99
dns_resolution_latency_ms p50/p95/p99
upstream_connect_latency_ms p50/p95/p99

If you cannot do true percentiles easily in the first version, start with:

count
sum
min
max
bucketed histogram

Then calculate approximations.

For NGINX/OpenResty, this can be done in shared dict counters/histograms and flushed periodically, or by a local sidecar/agent reading a local stats file/socket.