# Fail2Ban Cloudflare Integration

This repository contains custom `fail2ban` configurations for two WordPress websites, `revistaposidonia.com` and `enfantterrible.com.ar`. The primary purpose of these configurations is to use **Fail2Ban** to detect malicious login attempts, XML-RPC attacks, and other probing activities and then automatically ban the offending IP addresses using the **Cloudflare Firewall API**.

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

* **`action.d/`**: Contains the custom action to interact with the Cloudflare API.

    * `cloudflare-zone.conf`: Defines the `actionban` and `actionunban` commands that use `curl` to add and remove IP addresses from a Cloudflare Firewall rule.

## Deployment

This repository includes a `deploy.sh` script to automate the installation and configuration of the Fail2Ban rules on a server.

### Usage

The deployment script is designed to be executed directly from a URL. This method fetches the latest version of the script and executes it in a single command.

You can use `curl` or `wget` to run the script:

**Using `curl`**

```bash
curl -s [https://raw.githubusercontent.com/tingeka/fail2ban-rules/main/deploy.sh](https://raw.githubusercontent.com/tingeka/fail2ban-rules/main/deploy.sh) | sudo bash -s --
```

**Using `wget`**

```bash
wget -qO- [https://raw.githubusercontent.com/tingeka/fail2ban-rules/main/deploy.sh](https://raw.githubusercontent.com/tingeka/fail2ban-rules/main/deploy.sh) | sudo bash -s --
```

> **Note:** The `-s` flag tells `bash` to read commands from standard input, and the `--` flag marks the end of command-line options. This is a more explicit and secure way to execute the piped script.

### Script Functionality

The `deploy.sh` script performs the following actions:

1.  **Creates a Backup**: It creates a timestamped backup directory (e.g., `/etc/fail2ban/backup-20250804-174445`) and copies any existing `jail.d`, `filter.d`, and `action.d` files into it.

2.  **Downloads Files**: It downloads the `.conf` files from a specified GitHub repository URL.

3.  **Prompts for Overwrite**: If a configuration file already exists on the server, the script prompts you to confirm if you want to overwrite it.

4.  **Sets Permissions**: After successfully downloading each file, it sets the correct file permissions (`644` for filters/actions and `640` for jails).

5.  **Provides Post-Deployment Instructions**: After all files are downloaded, it reminds you to:

    * Update the Cloudflare Zone IDs and API tokens in the jail files.

    * Run `fail2ban-client -d` to check the syntax of the new configurations.

    * Restart the `fail2ban` service with `sudo systemctl restart fail2ban`.

### Automating the License

To automate the download of a license, you can add a simple line to your `deploy.sh` script, which will download a `LICENSE` file from your repository and place it in the current directory.

```bash
# Add this line to your deploy.sh script
download_file "LICENSE" "$REPO_BASE/LICENSE"
```

## Configuration

### Prerequisites

1.  **Fail2Ban**: Must be installed on your server.

2.  **`wp-fail2ban` plugin**: Recommended for WordPress websites to log authentication attempts to `auth.log`, allowing for more granular filtering.

3.  **Cloudflare API Token**: You need a Cloudflare API token with **Zone > Firewall** permissions.

### Manual Setup

1.  Place the files in their respective directories within your Fail2Ban configuration (e.g., `/etc/fail2ban/`).

2.  Update the `cloudflare-zone.conf` file with your specific Cloudflare zone ID and API token.

    * Replace `YOUR_SITE2_ZONE_ID` with your Cloudflare Zone ID.

    * Replace `YOUR_SITE2_API_TOKEN` with your Cloudflare API token.

    * **Note**: This is also referenced in the `jail.d` files, so ensure consistency.

3.  Ensure the `logpath` in the `jail.d` files matches the path of your Nginx access logs and `auth.log`.

4.  Disable the global Fail2Ban WordPress rules by setting `enabled = false` in `/etc/fail2ban/jail.local` or similar global configuration files to avoid conflicts.

5.  Restart the Fail2Ban service to apply the new configuration.

```bash
sudo systemctl restart fail2ban
```

## Jails Overview

Each website has a set of jails to protect against different types of attacks:

* **`*-wp-login`**: Blocks brute-force login attempts to `wp-login.php`. It uses incremental banning, starting with a 1-hour ban time that doubles with each subsequent offense, up to 5 weeks.

* **`*-wp-xmlrpc`**: Blocks attacks on the `xmlrpc.php` endpoint.

* **`*-wp-hard`, `*-wp-soft`, `*-wp-extra`**: These jails are for use with the `wp-fail2ban` plugin and target different types of authentication and comment spam failures logged to `auth.log`.

* **`*-nginx-probing`**: A catch-all jail that detects common bot probing for `.env` files, `cgi-bin`, `wp-config.php`, and other known exploit patterns.

All jails are configured to use the `cloudflare-zone` action to ban IPs at the Cloudflare firewall level, protecting the site at the edge and reducing server load.
