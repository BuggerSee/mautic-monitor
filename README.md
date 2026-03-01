# Mautic Campaign Monitor

Live terminal dashboard for monitoring Mautic campaign sends with AWS SES integration.

![Bash](https://img.shields.io/badge/bash-5.x-green) ![License](https://img.shields.io/badge/license-MIT-blue)

## Features

- **System metrics** — CPU, memory, swap, disk usage, load average, disk I/O
- **Queue monitoring** — RabbitMQ email/hit queues, Doctrine failed queue
- **Process tracking** — Messenger workers, campaign/broadcast processes, PHP-FPM pool
- **MariaDB stats** — Active threads, queries/sec
- **AWS SES dashboard** — 24h quota usage, send rate, 1h/24h send stats, 15-min live rate
- **SES utilization** — CloudWatch-based avg/max/peak utilization (60-min window)
- **Token bucket state** — Real-time view of the file-based token bucket used for cross-worker rate limiting
- **Bounce/complaint tracking** — Color-coded rates with AWS threshold warnings
- **CSV logging** — Automatic logging for historical analysis

## Screenshot

```
═══════════════════════════════════════════════════════════════
  MAUTIC CAMPAIGN MONITOR   2026-03-01 14:30:00   (every 5s)
═══════════════════════════════════════════════════════════════

  SYSTEM
  CPU:       [████████░░░░░░░░░░░░░░░░░░░░░░]  27%
  Memory:    [██████████████████░░░░░░░░░░░░░]  60%  2400 / 4000 MB
  Swap:      128 MB
  Disk:      [████████████░░░░░░░░░░░░░░░░░░░]  42%
  Load:      1.20  0.95  0.80
  Disk I/O:  R: 12 KB/s  W: 45 KB/s

  QUEUES
  RabbitMQ emails:   3 msgs  (~2400 mails)
  RabbitMQ hits:     0 pending
  Doctrine failed:   0 pending

  PROCESSES
  Email workers:     4
  Hit workers:       2
  Failed workers:    1
  Campaign/Send:     1
  PHP-FPM pool:      8

  DATABASE
  Active threads:    2
  Queries/sec:       150

  SES API (AWS)  (refresh every 30s)
  24h quota:         [██████░░░░░░░░░░░░░░░░░░░░░░░░]  22%  44000 / 200000
  Max send rate:     80 /sec  (DSN ratelimit: 80, AWS limit: 84)
  Sent (1h):         5200
  Sent (24h):        44000
  Live rate (15m):   5.8 /sec
  Utilization (60m): avg 7.2%  max 15.1%  peak 15.1%
  Token bucket:      active (2s ago)  72.0 / 80 tokens (90%)
  Bounce rate:       0.03%  (24h: 32 bounces)
  Complaint rate:    0.0%  (24h: 0 complaints)
  Rejects (1h):      0
```

## Requirements

- Bash 5.x
- Python 3 (for JSON parsing)
- PHP CLI (for reading Mautic DSN config)
- AWS CLI (configured with SES/CloudWatch permissions)
- MySQL/MariaDB client
- RabbitMQ (`rabbitmqctl`)
- Access to `/proc/stat`, `/proc/meminfo`, `/proc/diskstats`

## Installation

```bash
curl -o /usr/local/bin/mautic-monitor https://raw.githubusercontent.com/BuggerSee/mautic-monitor/main/mautic-monitor.sh
chmod +x /usr/local/bin/mautic-monitor
```

## Usage

```bash
# Default: refresh every 5 seconds
./mautic-monitor.sh

# Custom interval
./mautic-monitor.sh 10
```

## Configuration

All settings are configurable via environment variables:

| Variable | Default | Description |
|---|---|---|
| `MAUTIC_DB` | `mautic` | MariaDB database name |
| `MAUTIC_ROOT` | `/var/www/html/mautic` | Mautic installation root |
| `MAUTIC_CONFIG` | `$MAUTIC_ROOT/docroot/config/local.php` | Mautic config file (for DSN ratelimit) |
| `RABBIT_VHOST` | `%2f` | RabbitMQ vhost |
| `LOG_FILE` | `/var/log/mautic-monitor.csv` | CSV log output path |
| `AWS_REGION` | `eu-west-1` | AWS region for SES/CloudWatch |
| `SES_REFRESH` | `6` | Refresh SES API every N iterations |
| `BUCKET_FILE` | `$MAUTIC_ROOT/var/cache/prod/ses_token_bucket.json` | Token bucket file path |
| `BATCH_SIZE` | `800` | Estimated recipients per queue message |

Example:

```bash
MAUTIC_ROOT=/opt/mautic AWS_REGION=us-east-1 ./mautic-monitor.sh 3
```

## Token Bucket

The monitor reads the file-based token bucket used by the [eTailors Amazon SES plugin](https://github.com/BuggerSee/etailors_amazon_ses/tree/feature/token-bucket-rate-limiting) for cross-worker rate limiting. It shows:

- **active/idle** — whether workers are actively consuming tokens
- **tokens / capacity** — current tokens vs. the configured rate limit
- **capacity source** — uses `ratelimit` from your Mautic DSN (if set), falls back to the AWS API `MaxSendRate`

## CSV Logging

Every iteration appends a row to the CSV log file for historical analysis:

```
timestamp,cpu_pct,mem_pct,mem_used_mb,swap_used_mb,disk_io_read_kbs,disk_io_write_kbs,rabbit_email,rabbit_hit,rabbit_failed,mautic_workers,mariadb_threads,mariadb_qps,load_1m,load_5m,ses_api_1h,ses_api_24h,ses_bounces,ses_complaints,ses_rejects,ses_quota_pct,ses_util_avg,ses_util_max,ses_peak_util
```

## License

MIT
