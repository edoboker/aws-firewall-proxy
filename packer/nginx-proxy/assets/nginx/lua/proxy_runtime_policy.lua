-- Auto-generated bootstrap policy. The AppConfig runtime sync service
-- replaces this file with the current policy before nginx starts.
return {
    dns = {
        resolvers = { "169.254.169.253" },
        queries_per_sni = 1,
    },
    enforcement = {
        mode = "strict",
    },
}
