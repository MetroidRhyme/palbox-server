# config.example.ps1
# ---------------------------------------------------------------------------------
# Copy this file to  config.ps1  (which is git-ignored) and fill in your values.
# These are NOT secrets -- they are Cloudflare resource names you can see in your own
# dashboard -- but keeping them out of tracked files lets you fork/share the repo cleanly.
#
# Only the PUBLIC-SITE scripts (deploy_public_site.ps1, sync_public_data.ps1,
# push_server_messages.ps1) read this. If you only run the local server + dashboard,
# you do not need a config.ps1 at all.
# ---------------------------------------------------------------------------------

# Cloudflare Pages project name (the Direct-Upload project that serves the public site).
$PagesProject = 'your-pages-project'

# Cloudflare R2 bucket name (holds the frequently-changing per-player data).
$R2Bucket = 'your-r2-bucket'

# NOTE: the Cloudflare API token + account id are read from ENVIRONMENT VARIABLES
# (CLOUDFLARE_API_TOKEN with Pages:Edit + Workers R2 Storage:Edit, and CLOUDFLARE_ACCOUNT_ID)
# and are never stored in any file. Set them once as user environment variables. See docs.
#
# The Worker's identity (admin emails, email->GUID map, Access team domain + AUD, allowed host)
# is NOT here either -- it comes from Cloudflare Pages environment variables. See
# docs/04-public-site.md ("Worker identity").
