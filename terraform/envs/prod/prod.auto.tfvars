# Non-secret settings for the prod stack. EDIT the CHANGE_ME values before applying.
region = "us-east-1"

root_domain        = "bishnuthapa.info.np"
app_subdomains     = ["app"]               # => https://app.bishnuthapa.info.np
cloudflare_zone_id = "CHANGE_ME"           # Cloudflare dashboard > bishnuthapa.info.np > Overview (right column)
github_repository  = "CHANGE_ME/CHANGE_ME" # owner/repo that may deploy

alarm_email = "" # set an address to receive CloudWatch alarms (needs a confirmation click)

# true = one NAT gateway instead of one per AZ (cheaper, less resilient)
single_nat_gateway = false
