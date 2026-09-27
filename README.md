# Remnawave Installer

**Remnawave Installer** is an open-source installer and operations menu for building a Remnawave stack without hand-assembling every service, proxy rule, certificate, and node connection yourself.

It is designed for clean VPS deployments where you want to go from an empty server to a working Remnawave setup with a guided flow, then keep the same tool around for maintenance.

The installer targets **Remnawave v3 only**. It does not support v2 or migrate existing v2 installations. New installations use the matching `.env` and Compose templates from release `3.4.4`, with the backend image on the `:3` channel. Updates stay within that major version; explicitly pinned `3.x` image tags remain pinned.

## Overview

The project helps deploy and manage:

- Remnawave Panel
- Remnawave Node
- Remnawave subscription page
- Caddy or NGINX reverse proxy
- TLS certificates
- backups and restore
- optional native WARP routing
- creator support information

Instead of being a one-time script that disappears after installation, **Remnawave Installer** behaves like a small server console. You can install, update, restart, inspect logs, reconfigure the subscription page, work with certificates, and manage nodes from the same menu.

## Supported Systems

| Distribution | Status | Notes |
| --- | --- | --- |
| Ubuntu 22.04 LTS | Supported | Recommended stable target |
| Ubuntu 24.04 LTS | Supported | Recommended new target |
| Debian 12 | Planned | Not enabled until tested end-to-end |
| Other apt-based systems | Experimental idea | Requires validation before support |

## Deployment Modes

### Single Server

Panel, Node, reverse proxy, certificates, and subscription page are installed on one machine.

Best for:

- personal setups
- small deployments
- testing
- fast first launch

### Distributed

Panel runs on one server, while Nodes run on separate machines.

Best for:

- scaling traffic
- separating management from edge nodes
- running several locations
- cleaner production topology

### Maintenance Mode

After installation, the same menu can be used to manage the stack:

- start, stop, restart
- update services
- view logs
- recreate subscription page
- reinstall while preserving data
- create backups
- restore from backups
- manage WARP native routing
- open Support Creator details

## Domain Plan

Prepare DNS before running the installer.

Recommended layout:

| Purpose | Example |
| --- | --- |
| Panel | `panel.example.com` |
| Subscription page | `sub.example.com` |
| Node address | `node.example.com` or server IP |

For certificate issuance, these records must point to the correct server and ports `80/tcp` and `443/tcp` must be reachable.

## Quick Start

<img src="imgs/mainframe.png" alt="Mainframe" width="800">

Download the installer and run it as root:

```bash
bash remnawave_installer.sh
```

The entrypoint can be exposed as a one-line install command:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/cluedesc/remnawave-installer/main/remnawave_installer.sh)
```

## Menu

```text
1. Install
2. Panel
3. Node
4. System
5. WARP native
6. Certificates
7. Backup / Restore
8. Support Creator
0. Exit
```

## Features

### Installation

- Panel installation
- Node installation
- combined Panel + Node installation
- base package setup
- Docker and Docker Compose setup
- guided first admin creation

### Reverse Proxy

- Caddy support
- NGINX + Certbot support
- automatic TLS flow
- dedicated subscription page domain
- clean root response for subscription domain
- real subscription paths proxied to the subscription page service

### Subscription Page

- separate service configuration
- separate public domain
- automatic API token creation
- compose override instead of destructive edits

### Node Management

- guided Node setup
- Panel API authentication
- config profile selection
- inbound selection
- automatic Node creation when possible
- manual secret fallback when needed

### Maintenance

- service status
- logs
- update
- restart
- reinstall while preserving config and volumes
- safe removal modes
- backup and restore

Panel updates and reinstalls require a successful database backup. Reinstall preserves the existing Compose files, `.env`, and Docker volumes; it does not replace your service configuration with a downloaded template. The database and Redis start first, followed by the backend; dependent services start after the backend becomes healthy.

### Backup and Restore

Full backups contain a PostgreSQL custom-format dump, Panel and Node configuration, the subscription Compose override, installer state, and the managed Caddy/NGINX configuration files. A failed dump or archive operation does not publish a backup. Archives are private and contain credentials: store an off-server copy securely.

If the database is stopped, backup starts only PostgreSQL and returns it to its stopped state afterwards. Application services remain stopped during this operation.

Restore validates the archive and dump before replacing configuration or the database. It stops the existing services, restores the database, and starts the stack only after database restoration succeeds. Failures are reported; do not treat an unsuccessful restore as a usable deployment. Older configuration-only archives cannot be used for full restore.

For recovery on another server, install Docker/Compose and the chosen reverse proxy first. The PostgreSQL image referenced by the saved Compose file must already be available locally for dump validation. Docker images, TLS certificate storage, firewall rules, and WARP configuration are not included in these backups. Reissue or restore certificates separately and validate/reload the reverse proxy after recovery.

### Readiness Checks

Panel checks require a successful API response and valid HTTPS certificates. Subscription checks verify the service's internal health separately from the public HTTPS endpoint. Check an existing user's subscription URL to verify complete subscription delivery; the public root response alone does not prove it.

### WARP Native

- native WireGuard-based WARP interface
- start, stop, restart, remove
- status checks
- add or remove `warp-out` in a Remnawave config profile

### Support Creator

- visible `Support Creator` item in the main menu
- first-run support notice with the same support details
- crypto support options
- Tribute support link
- DonationAlerts support link

Support options:

| Method | Address / Link |
| --- | --- |
| BTC | `bc1quktsqka8g3tgd5thz8y2n93v2n8xga8yk5acd7` |
| ETH | `0x54fA3BAd92643EcDD599717F61515499cB493bb6` |
| ERC20/BEP20 | `0x54fA3BAd92643EcDD599717F61515499cB493bb6` |
| SOL | `DvULVG6Wi5ABLhr9UBHup6CJrQUsrnufjqwBiZGEgTWz` |
| ZEC | `t1TP7jQyFVs5LFzqVv7hPfZYfHPMrTcuyC4` |
| Tribute | <https://t.me/tribute/app?startapp=dMLC> |
| DonationAlerts | <https://donationalerts.com/r/cluedesc> |

## What Makes It Different

**Remnawave Installer** focuses on the whole operator experience, not only the first install.

It keeps the common tasks close:

- install the stack
- verify it
- fix it
- update it
- add a node
- configure subscription page
- recover from backup
- support the creator
- return to the menu

The goal is simple: fewer fragile manual steps, fewer repeated prompts, and a clearer path from empty VPS to maintained Remnawave service.

## Safety Notes

Run this on a fresh or predictable server.

Before installation, make sure you understand:

- which domains point to which server
- which web server you want to use
- whether Cloudflare proxy is enabled or disabled
- which firewall rules are active
- where Panel and Node should live

The installer avoids broad destructive cleanup and does not use global Docker pruning as part of normal operations.

## Roadmap

Potential future work:

- Debian support
- release-based install command
- better non-interactive mode
- richer diagnostics
- automatic environment report
- configuration export/import
- safer migration tools

## Community

This project is intended to be open, readable, and practical. Issues, fixes, deployment notes, and documentation improvements are welcome.

If you use it on a real server, include your distribution, version, virtualization type, and reverse proxy choice when reporting problems. That information matters more than a generic "does not work" report.

## Regression Checks

The tests require Bash, jq, OpenSSL, and standard Unix tools. They use temporary files and mock Docker/HTTP calls; they do not install services or contact a running Panel.

```bash
bash -n remnawave_installer.sh
for test_file in tests/*.sh; do bash "$test_file" || exit 1; done
```

A real Ubuntu/Docker installation and database restore should also be checked before a production deployment.
