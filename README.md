# Fail2Ban Cloudflare Integration

This repository contains custom `fail2ban` configurations for two WordPress websites. The primary purpose of these configurations is to use **Fail2Ban** to detect malicious login attempts, XML-RPC attacks, and other probing activities and then automatically ban the offending IP addresses using the **Cloudflare Rulesets API** to manage a dynamic ban list.

## Contents

* **`jail.d/`**: Contains the main `fail2ban` jail configurations for each website.
 
    * `posidonia.conf`: Jails for `revistaposidonia.com`.

    * `enfant.conf`: Jails for `enfantterrible.com.ar`.

* **`filter.d/`**: Contains the custom filters used by the jails. These filters define the regular expressions used to match malicious entries in the log files.

    * `wordpress-wp-login.conf`: Matches failed login attempts to `wp-login.php`.

    * `wordpress-xmlrpc.conf`: Matches attacks on the `xmlrpc.php` file.

    * `rp-wp-hard.conf`, `rp-wp-soft.conf`, `rp-wp-extra.conf`: Filters for the `wp-fail2ban` plugin, specifically configured for `revistaposidonia.com`.

    * `et-wp-hard.conf`, `et-wp-soft.conf`, `et-wp-extra.conf`: Filters for the `wp-fail2ban` plugin, specifically configured for `enfantterrible.com.ar`.

    * `nginx-probing.conf`: A custom filter to catch various bot probing attempts in the Nginx access logs.

* **`action.d/`**: Contains the custom action to interact with the Cloudflare Rulesets API.

    * `cloudflare-zone.conf`: Defines the actionstart, actionban, and actionunban commands that internally call a shell script (f2b-action-cloudflare-zone.sh) to manage a single Cloudflare custom rule.

* **`bin/`**: Contains the executable logic for Cloudflare integration.

    * `f2b-action-cloudflare-zone.sh`: A robust and idempotent script that implements Fail2Ban action hooks for Cloudflare. It handles caching, locking, API interaction, and IP ban list management. 

## Deployment

This repository includes a `deploy.sh` script to automate the installation and configuration of the Fail2Ban rules on a server.

### Script Functionality

The `deploy.sh` script performs these actions **in order**:

1. **Validates Inputs**:  
   - Errors if `--profile`, `--zone-id`, `--api-token`, or `--rule-name` are missing.  
   - Ensures Fail2Ban is installed.

2. **Creates Backup**:  
   - Automatically backs up existing configs to `/etc/fail2ban/backup-<timestamp>`.  
   - No prompts — backups always run.

3. **Downloads Files**:  
   - Fetches profile-specific filters and jail files from GitHub.  
   - Prompts before overwriting files (unless `--yes` is used).

4. **Injects Cloudflare Credentials**:  
   - Replaces `{{ZONE_ID}}`, `{{API_TOKEN}}`, and `{{RULE_NAME}}` placeholders in jail files.  
   - **No manual edits required**.

5. **Configures Dynamic Ban Logic**:  
   - Sets up the Cloudflare action script to use a file-based ban list.  
   - Ensures IPs are tracked across ban/unban events using safe locking and caching.  
   - Cloudflare API calls are rate-limited and resilient to failure.

6. **Finalizes Deployment**:  
   - Sets file permissions (`640` for jails, `644` for filters/actions).  
   - Prints explicit commands to restart Fail2Ban.

### Cloudflare Rule Requirements

This integration requires a preexisting custom WAF rule in your Cloudflare account:

1. Navigate to:  
   **Security → WAF → Custom Rules → Rule sets**

2. Create a new **custom ruleset** in the `http_request_firewall_custom` phase.

3. Add a single rule with the following:

   - **Description**: A unique name (e.g., `Fail2Ban-Dynamic-Ban-List`) — must match `cfrule` in jail config.
   - **Action**: `Block`
   - **Expression**: Placeholder like `ip.src eq 0.0.0.0`

This rule will be automatically patched at runtime with dynamic expressions like:

```txt
ip.src in {1.2.3.4 5.6.7.8}
# The expression is regenerated on every ban or unban
# event and reflects the current persistent ban list.
```

### Prerequisites

1. **Fail2Ban**: Installed and running. The script will fail if not detected.  
2. **Cloudflare API Token**:  
   - Requires `Zone > Zone WAF: Edit` and `Zone > Firewall Services: Edit` permissions.  
   - Must be provided via `--api-token`.
3. **CloudFlare Zone ID**
    - Must be provided via `--zone-id`.
4. **Profile Selection**:  
   - Use `enfant` for `enfantterrible.com.ar`.  
   - Use `posidonia` for `revistaposidonia.com`.  

> **Critical Change**:  
> The script **no longer uses placeholder values**. Cloudflare credentials must be passed via CLI arguments.

### Usage

The deployment script is designed to be executed directly from a URL. This method fetches the latest version of the script and executes it in a single command.

You can use `curl` or `wget` to run the script:

**Using `curl`**

```bash
curl -s https://raw.githubusercontent.com/tingeka/fail2ban-rules/main/deploy.sh | sudo bash -s -- \
  --profile <enfant|posidonia> \
  --zone-id <CLOUDFLARE_ZONE_ID> \
  --api-token <CLOUDFLARE_API_TOKEN> \
  --rule-name <CLOUDFLARE_RULE_NAME> \
  [--yes]
```

**Using `wget`**

```bash
wget -qO- https://raw.githubusercontent.com/tingeka/fail2ban-rules/main/deploy.sh | sudo bash -s -- \
  --profile <enfant|posidonia> \
  --zone-id <CLOUDFLARE_ZONE_ID> \
  --api-token <CLOUDFLARE_API_TOKEN> \
  --rule-name <CLOUDFLARE_RULE_NAME> \
  [--yes]
```

> **Note:**
> - The `-s` flag tells `bash` to read commands from standard input.
> - The `--` flag marks the end of command-line options. This is a more explicit and secure way to execute the piped script.
> - The `--profile` flag is mandatory.
> - The `--zone-id`, `--api-token`, and `--rule-name` flags are now required.
> - The `--yes` flag skips confirmation prompts.

## Manual Setup

1.  Place the files in their respective directories within your Fail2Ban configuration (e.g., `/etc/fail2ban/`).

2.  Update the `cloudflare-zone.conf` file with your specific Cloudflare zone ID and API token.

    * Replace `{{ZONE_ID}}` with your Cloudflare Zone ID.

    * Replace `{{API_TOKEN}}` with your Cloudflare API token.

    * Replace `{{RULE_NAME}}` with your Cloudflare rule name. 
    
    * Ensure all jail actions include the `cfrule` argument (e.g., `cloudflare-zone[cfzone=…, cftoken=…, cfrule=…]`). 

    * **Note**: This is also referenced in the `jail.d` files, so ensure consistency.

3.  Ensure the `logpath` in the `jail.d` files matches the path of your Nginx access logs and `auth.log`.

4.  Disable the global Fail2Ban WordPress rules by setting `enabled = false` in `/etc/fail2ban/jail.local` or similar global configuration files to avoid conflicts.

5. Check for syntax errors before applying the new configuration:

```bash
sudo fail2ban-client -d
```  

6.  Restart the Fail2Ban service to apply the new configuration.

```bash
# Common
sudo systemctl restart fail2ban
# Gridpane specific
sudo services fail2ban restart
```

## Jails Overview

Each website has a set of jails to protect against different types of attacks:

* **`*-wp-login`**: Blocks brute-force login attempts to `wp-login.php`. It uses incremental banning, starting with a 1-hour ban time that doubles with each subsequent offense, up to 5 weeks.

* **`*-wp-xmlrpc`**: Blocks attacks on the `xmlrpc.php` endpoint.

* **`*-wp-hard`, `*-wp-soft`, `*-wp-extra`**: These jails are for use with the `wp-fail2ban` plugin and target different types of authentication and comment spam failures logged to `auth.log`.

* **`*-nginx-probing`**: A catch-all jail that detects common bot probing for `.env` files, `cgi-bin`, `wp-config.php`, and other known exploit patterns.

All jails are configured to use the `cloudflare-zone` action to ban IPs at the Cloudflare firewall level, protecting the site at the edge and reducing server load.
