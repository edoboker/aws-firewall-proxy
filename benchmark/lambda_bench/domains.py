"""Curated list of well-known, reliably-resolvable FQDNs for the lambda
IP-fallback scaling benchmark.

The fallback Lambda raises (and the invoke fails) if *any* FQDN returns no
IPv4 answer, so this list deliberately sticks to large, globally-anycast,
A-record-having domains. Order is stable: step N uses DOMAINS[:N], so the
small steps are a strict subset of the large ones.
"""

# ~320 entries -> headroom above the largest benchmark step (300).
DOMAINS = [
    # Search / portals / big tech
    "google.com", "youtube.com", "facebook.com", "instagram.com", "x.com",
    "twitter.com", "linkedin.com", "reddit.com", "wikipedia.org", "yahoo.com",
    "bing.com", "duckduckgo.com", "baidu.com", "yandex.com", "amazon.com",
    "microsoft.com", "apple.com", "icloud.com", "office.com", "outlook.com",
    "live.com", "msn.com", "bing.net", "google.co.uk", "google.de",
    "google.fr", "google.co.in", "google.com.br", "google.ca", "google.com.au",
    # AI
    "chatgpt.com", "openai.com", "anthropic.com", "claude.ai", "gemini.google.com",
    "perplexity.ai", "huggingface.co", "midjourney.com", "stability.ai", "cohere.com",
    # Cloud / infra / dev
    "amazonaws.com", "aws.amazon.com", "azure.com", "azure.microsoft.com", "cloud.google.com",
    "cloudflare.com", "github.com", "gitlab.com", "bitbucket.org", "docker.com",
    "hub.docker.com", "pypi.org", "npmjs.com", "rubygems.org", "nuget.org",
    "packagist.org", "crates.io", "golang.org", "go.dev", "kubernetes.io",
    "terraform.io", "hashicorp.com", "ansible.com", "redhat.com", "ubuntu.com",
    "debian.org", "kernel.org", "archlinux.org", "fedoraproject.org", "centos.org",
    "stackoverflow.com", "stackexchange.com", "serverfault.com", "superuser.com", "askubuntu.com",
    "digitalocean.com", "heroku.com", "vercel.com", "netlify.com", "render.com",
    "fly.io", "linode.com", "vultr.com", "ovh.com", "hetzner.com",
    "datadoghq.com", "newrelic.com", "pagerduty.com", "sentry.io", "grafana.com",
    "elastic.co", "mongodb.com", "redis.io", "postgresql.org", "mysql.com",
    # SaaS / productivity
    "slack.com", "zoom.us", "dropbox.com", "box.com", "notion.so",
    "atlassian.com", "jira.atlassian.com", "confluence.atlassian.com", "trello.com", "asana.com",
    "monday.com", "clickup.com", "airtable.com", "figma.com", "canva.com",
    "miro.com", "calendly.com", "docusign.com", "salesforce.com", "hubspot.com",
    "zendesk.com", "intercom.com", "freshworks.com", "servicenow.com", "workday.com",
    "sap.com", "oracle.com", "ibm.com", "adobe.com", "intuit.com",
    "quickbooks.intuit.com", "mailchimp.com", "sendgrid.com", "twilio.com", "stripe.com",
    "paypal.com", "squareup.com", "shopify.com", "wix.com", "squarespace.com",
    "wordpress.com", "wordpress.org", "godaddy.com", "namecheap.com", "cloudns.net",
    # Auth / identity
    "login.microsoftonline.com", "accounts.google.com", "okta.com", "auth0.com", "onelogin.com",
    "duo.com", "1password.com", "lastpass.com", "bitwarden.com", "dashlane.com",
    # News / media
    "cnn.com", "bbc.com", "bbc.co.uk", "nytimes.com", "theguardian.com",
    "washingtonpost.com", "reuters.com", "bloomberg.com", "ft.com", "wsj.com",
    "forbes.com", "businessinsider.com", "cnbc.com", "apnews.com", "npr.org",
    "aljazeera.com", "dw.com", "lemonde.fr", "spiegel.de", "elpais.com",
    "techcrunch.com", "theverge.com", "wired.com", "arstechnica.com", "engadget.com",
    "zdnet.com", "cnet.com", "gizmodo.com", "mashable.com", "venturebeat.com",
    "hbr.org", "economist.com", "time.com", "theatlantic.com", "newyorker.com",
    "ynet.co.il", "haaretz.com", "timesofisrael.com", "jpost.com", "calcalist.co.il",
    # Streaming / entertainment
    "netflix.com", "spotify.com", "twitch.tv", "disneyplus.com", "hulu.com",
    "hbomax.com", "max.com", "primevideo.com", "soundcloud.com", "vimeo.com",
    "dailymotion.com", "imdb.com", "rottentomatoes.com", "pandora.com", "deezer.com",
    "tidal.com", "last.fm", "bandcamp.com", "audible.com", "crunchyroll.com",
    # Social / messaging / community
    "discord.com", "whatsapp.com", "telegram.org", "signal.org", "snapchat.com",
    "tiktok.com", "pinterest.com", "tumblr.com", "medium.com", "substack.com",
    "quora.com", "flickr.com", "deviantart.com", "behance.net", "dribbble.com",
    "producthunt.com", "hackernews.com", "ycombinator.com", "indiehackers.com", "dev.to",
    "patreon.com", "onlyfans.com", "kick.com", "rumble.com", "bsky.app",
    "mastodon.social", "threads.net", "vk.com", "ok.ru", "weibo.com",
    # E-commerce / retail
    "ebay.com", "etsy.com", "walmart.com", "target.com", "bestbuy.com",
    "aliexpress.com", "alibaba.com", "taobao.com", "jd.com", "rakuten.com",
    "wayfair.com", "ikea.com", "homedepot.com", "lowes.com", "costco.com",
    "newegg.com", "wish.com", "temu.com", "shein.com", "asos.com",
    "zalando.com", "nike.com", "adidas.com", "zara.com", "hm.com",
    # Travel
    "booking.com", "expedia.com", "airbnb.com", "tripadvisor.com", "kayak.com",
    "hotels.com", "agoda.com", "skyscanner.com", "uber.com", "lyft.com",
    "delta.com", "united.com", "aa.com", "lufthansa.com", "emirates.com",
    "marriott.com", "hilton.com", "ihg.com", "hyatt.com", "accor.com",
    # Finance / banking
    "chase.com", "bankofamerica.com", "wellsfargo.com", "citi.com", "capitalone.com",
    "americanexpress.com", "visa.com", "mastercard.com", "fidelity.com", "schwab.com",
    "vanguard.com", "robinhood.com", "coinbase.com", "binance.com", "kraken.com",
    "blockchain.com", "plaid.com", "wise.com", "revolut.com", "klarna.com",
    # Education / reference
    "coursera.org", "edx.org", "udemy.com", "khanacademy.org", "udacity.com",
    "duolingo.com", "mit.edu", "harvard.edu", "stanford.edu", "berkeley.edu",
    "ox.ac.uk", "cam.ac.uk", "nature.com", "sciencedirect.com", "springer.com",
    "ieee.org", "acm.org", "arxiv.org", "researchgate.net", "jstor.org",
    "britannica.com", "dictionary.com", "merriam-webster.com", "wolframalpha.com", "wikihow.com",
    # CDNs / infra endpoints (resolve fine, useful tail)
    "cloudfront.net", "akamai.com", "akamaized.net", "fastly.com", "jsdelivr.net",
    "unpkg.com", "cdnjs.com", "gstatic.com", "googleapis.com", "googleusercontent.com",
    "youtu.be", "fbcdn.net", "twimg.com", "redditstatic.com", "abs.twimg.com",
    "wp.com", "gravatar.com", "imgur.com", "giphy.com", "tenor.com",
    # Misc high-traffic
    "wix.com", "weather.com", "accuweather.com", "espn.com", "nba.com",
    "nfl.com", "fifa.com", "uefa.com", "yelp.com", "glassdoor.com",
    "indeed.com", "ziprecruiter.com", "monster.com", "crunchbase.com", "trustpilot.com",
    "speedtest.net", "whatismyip.com", "ipinfo.io", "ifconfig.me", "example.com",
]
