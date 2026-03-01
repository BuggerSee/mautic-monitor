#!/usr/bin/env bash
# mautic-monitor.sh — Live dashboard for Mautic campaign sends
# Usage: ./mautic-monitor.sh [interval_seconds]  (default: 5)

set -euo pipefail

INTERVAL="${1:-5}"
MAUTIC_DB="${MAUTIC_DB:-mautic}"
MAUTIC_ROOT="${MAUTIC_ROOT:-/var/www/html/mautic}"
RABBIT_VHOST="${RABBIT_VHOST:-%2f}"
LOG_FILE="${LOG_FILE:-/var/log/mautic-monitor.csv}"
AWS_REGION="${AWS_REGION:-eu-west-1}"
SES_REFRESH="${SES_REFRESH:-6}"   # refresh SES API every N iterations (avoid API slowdown)
BUCKET_FILE="${BUCKET_FILE:-${MAUTIC_ROOT}/var/cache/prod/ses_token_bucket.json}"
MAUTIC_CONFIG="${MAUTIC_CONFIG:-${MAUTIC_ROOT}/docroot/config/local.php}"
BATCH_SIZE="${BATCH_SIZE:-800}"

# Colors
R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m' C='\033[0;36m' B='\033[1m' N='\033[0m'

bar() {
  local pct=$1 width=30 filled
  filled=$(( pct * width / 100 ))
  local color="$G"
  (( pct > 70 )) && color="$Y"
  (( pct > 90 )) && color="$R"
  printf "${color}["
  printf '%0.s█' $(seq 1 $filled 2>/dev/null) || true
  printf '%0.s░' $(seq 1 $(( width - filled )) 2>/dev/null) || true
  printf "]${N} %3d%%" "$pct"
}

# Write CSV header once
if [[ ! -f "$LOG_FILE" ]]; then
  echo "timestamp,cpu_pct,mem_pct,mem_used_mb,swap_used_mb,disk_io_read_kbs,disk_io_write_kbs,rabbit_email,rabbit_hit,rabbit_failed,mautic_workers,mariadb_threads,mariadb_qps,load_1m,load_5m,ses_api_1h,ses_api_24h,ses_bounces,ses_complaints,ses_rejects,ses_quota_pct,ses_util_avg,ses_util_max,ses_peak_util" > "$LOG_FILE"
fi

prev_reads=0
prev_writes=0
prev_queries=0
prev_ts=0
iteration=0

# CPU delta state (from /proc/stat)
prev_cpu_total=0
prev_cpu_idle=0

# SES API cached state
ses_api_max_rate="—"
ses_api_24h_limit="—"
ses_api_sent_24h="—"
ses_api_quota_pct="—"
ses_api_1h_sent="—"
ses_api_1h_bounces="—"
ses_api_1h_complaints="—"
ses_api_1h_rejects="—"
ses_api_24h_sent="—"
ses_api_24h_bounces="—"
ses_api_24h_complaints="—"
ses_api_24h_rejects="—"
ses_api_bounce_pct="—"
ses_api_complaint_pct="—"
ses_api_15m_rate="—"
ses_util_avg="—"
ses_util_max="—"
ses_peak_util=0

clear  # initial clear only
while true; do
  tput home        # move cursor to top-left (no flicker)
  now=$(date '+%Y-%m-%d %H:%M:%S')
  ts_epoch=$(date +%s)

  # ── CPU (delta from /proc/stat — accurate, lightweight) ──
  read -r _ cpu_us cpu_ni cpu_sy cpu_id cpu_wa cpu_hi cpu_si cpu_st _ < /proc/stat
  cur_cpu_idle=$cpu_id
  cur_cpu_total=$(( cpu_us + cpu_ni + cpu_sy + cpu_id + cpu_wa + cpu_hi + cpu_si + cpu_st ))
  if (( prev_cpu_total > 0 )); then
    delta_total=$(( cur_cpu_total - prev_cpu_total ))
    delta_idle=$(( cur_cpu_idle - prev_cpu_idle ))
    if (( delta_total > 0 )); then
      cpu_pct=$(( (delta_total - delta_idle) * 100 / delta_total ))
    else
      cpu_pct=0
    fi
  else
    cpu_pct=0
  fi
  prev_cpu_total=$cur_cpu_total
  prev_cpu_idle=$cur_cpu_idle

  # ── Load average ──
  read -r load1 load5 load15 _ < /proc/loadavg

  # ── Memory ──
  read -r mem_total mem_avail <<< "$(awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} END{print t, a}' /proc/meminfo)"
  mem_used_mb=$(( (mem_total - mem_avail) / 1024 ))
  mem_total_mb=$(( mem_total / 1024 ))
  mem_pct=$(( (mem_total - mem_avail) * 100 / mem_total ))

  swap_used_mb=$(awk '/SwapTotal/{t=$2} /SwapFree/{f=$2} END{print int((t-f)/1024)}' /proc/meminfo)

  # ── Disk I/O (all devices combined) ──
  cur_reads=$(awk 'NR>1{r+=$4} END{print r+0}' /proc/diskstats)
  cur_writes=$(awk 'NR>1{w+=$8} END{print w+0}' /proc/diskstats)
  if (( prev_ts > 0 )); then
    dt=$(( ts_epoch - prev_ts ))
    (( dt == 0 )) && dt=1
    io_read_kbs=$(( (cur_reads - prev_reads) / 2 / dt ))   # sectors are 512B
    io_write_kbs=$(( (cur_writes - prev_writes) / 2 / dt ))
  else
    io_read_kbs=0
    io_write_kbs=0
  fi
  prev_reads=$cur_reads
  prev_writes=$cur_writes

  # ── Disk space ──
  disk_pct=$(df "$MAUTIC_ROOT" 2>/dev/null | awk 'NR==2{gsub(/%/,""); print $5}' || echo "0")

  # ── RabbitMQ queues ──
  rabbit_email=$(rabbitmqctl list_queues name messages 2>/dev/null | awk '/^emails\s/{print $2}' || echo "?")
  rabbit_hit=$(rabbitmqctl list_queues name messages 2>/dev/null | awk '/^hits\s/{print $2}' || echo "?")
  # Failed queue is Doctrine, query DB
  rabbit_failed=$(mysql -N -e "SELECT COUNT(*) FROM messenger_messages WHERE queue_name='fail'" "$MAUTIC_DB" 2>/dev/null || echo "?")

  # ── Mautic processes ──
  worker_email=$(pgrep -fc 'messenger:consume email' 2>/dev/null || true)
  [[ -z "$worker_email" ]] && worker_email=0
  worker_hit=$(pgrep -fc 'messenger:consume hit' 2>/dev/null || true)
  [[ -z "$worker_hit" ]] && worker_hit=0
  worker_failed=$(pgrep -fc 'messenger:consume failed' 2>/dev/null || true)
  [[ -z "$worker_failed" ]] && worker_failed=0
  worker_count=$(( worker_email + worker_hit + worker_failed ))
  campaign_procs=$(pgrep -fc 'mautic:campaigns:trigger|mautic:broadcasts:send' 2>/dev/null || true)
  [[ -z "$campaign_procs" ]] && campaign_procs=0
  php_fpm_count=$(pgrep -fc 'php-fpm.*pool' 2>/dev/null || true)
  [[ -z "$php_fpm_count" ]] && php_fpm_count=0

  # ── MariaDB ──
  db_threads=$(mysql -N -e "SHOW STATUS LIKE 'Threads_running'" "$MAUTIC_DB" 2>/dev/null | awk '{print $2}' || echo "?")
  db_queries=$(mysql -N -e "SHOW STATUS LIKE 'Queries'" "$MAUTIC_DB" 2>/dev/null | awk '{print $2}' || echo "0")
  if (( prev_ts > 0 && prev_queries > 0 )); then
    dt=$(( ts_epoch - prev_ts ))
    (( dt == 0 )) && dt=1
    qps=$(( (db_queries - prev_queries) / dt ))
  else
    qps=0
  fi
  prev_queries=$db_queries

  # ── Token bucket state ──
  # Get effective rate from Mautic DSN config (ratelimit param overrides AWS)
  if [[ -z "${bucket_rate:-}" ]]; then
    bucket_rate=$(php -r "
      include '$MAUTIC_CONFIG';
      \$dsn = \$parameters['mailer_dsn'] ?? '';
      if (preg_match('/[?&]ratelimit=(\d+)/', \$dsn, \$m)) echo \$m[1];
    " 2>/dev/null || true)
  fi

  bucket_info="—"
  bucket_tokens="—"
  bucket_capacity="—"
  bucket_pct="—"
  if [[ -f "$BUCKET_FILE" ]]; then
    bucket_mtime=$(stat -c '%Y' "$BUCKET_FILE" 2>/dev/null || echo 0)
    bucket_age=$(( ts_epoch - bucket_mtime ))
    bucket_json=$(cat "$BUCKET_FILE" 2>/dev/null || echo "{}")
    # Use configured rate, fall back to AWS API rate
    effective_rate="${bucket_rate:-$ses_api_max_rate}"
    bucket_tokens=$(echo "$bucket_json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(f'{d.get(\"tokens\", 0):.1f}')
" 2>/dev/null || echo "—")
    if [[ "$effective_rate" =~ ^[0-9]+$ ]] && (( effective_rate > 0 )); then
      bucket_capacity="$effective_rate"
      if [[ "$bucket_tokens" =~ ^[0-9.]+$ ]]; then
        bucket_pct=$(echo "$bucket_tokens $bucket_capacity" | awk '{printf "%.0f", ($1/$2)*100}')
      fi
    fi
    if (( bucket_age < INTERVAL * 2 )); then
      bucket_info="${G}active${N} (${bucket_age}s ago)"
    else
      bucket_info="${Y}idle${N} (${bucket_age}s ago)"
    fi
  fi

  # ── SES API (refreshed every N iterations to avoid slowing dashboard) ──
  if (( iteration % SES_REFRESH == 0 )); then
    # Quota
    ses_quota_json=$(aws ses get-send-quota --region "$AWS_REGION" --output json 2>/dev/null || echo "{}")
    ses_api_max_rate=$(echo "$ses_quota_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(int(d.get('MaxSendRate',0)))" 2>/dev/null || echo "—")
    ses_api_24h_limit=$(echo "$ses_quota_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(int(d.get('Max24HourSend',0)))" 2>/dev/null || echo "—")
    ses_api_sent_24h=$(echo "$ses_quota_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(int(d.get('SentLast24Hours',0)))" 2>/dev/null || echo "—")
    if [[ "$ses_api_sent_24h" =~ ^[0-9]+$ ]] && [[ "$ses_api_24h_limit" =~ ^[0-9]+$ ]] && (( ses_api_24h_limit > 0 )); then
      ses_api_quota_pct=$(( ses_api_sent_24h * 100 / ses_api_24h_limit ))
    fi

    # Send statistics (15-min buckets)
    ses_stats_json=$(aws ses get-send-statistics --region "$AWS_REGION" --output json 2>/dev/null || echo '{"SendDataPoints":[]}')
    read -r ses_api_1h_sent ses_api_1h_bounces ses_api_1h_complaints ses_api_1h_rejects \
            ses_api_24h_sent ses_api_24h_bounces ses_api_24h_complaints ses_api_24h_rejects \
            ses_api_15m_rate ses_api_bounce_pct ses_api_complaint_pct <<< "$(echo "$ses_stats_json" | python3 -c "
import json, sys
from datetime import datetime, timezone, timedelta

data = json.load(sys.stdin)
points = data.get('SendDataPoints', [])
now = datetime.now(timezone.utc)
h1 = now - timedelta(hours=1)
h24 = now - timedelta(hours=24)

s1=b1=c1=r1=s24=b24=c24=r24=0
latest_sent=0
latest_ts=None

for p in points:
    ts = datetime.fromisoformat(p['Timestamp'])
    if ts >= h1:
        s1 += p['DeliveryAttempts']; b1 += p['Bounces']; c1 += p['Complaints']; r1 += p['Rejects']
        # track most recent 15-min bucket for live rate
        if latest_ts is None or ts > latest_ts:
            latest_ts = ts; latest_sent = p['DeliveryAttempts']
    if ts >= h24:
        s24 += p['DeliveryAttempts']; b24 += p['Bounces']; c24 += p['Complaints']; r24 += p['Rejects']

rate_15m = round(latest_sent / 900, 1) if latest_sent > 0 else 0
bounce_pct = round(b24 / s24 * 100, 2) if s24 > 0 else 0
complaint_pct = round(c24 / s24 * 100, 3) if s24 > 0 else 0

print(f'{s1} {b1} {c1} {r1} {s24} {b24} {c24} {r24} {rate_15m} {bounce_pct} {complaint_pct}')
" 2>/dev/null || echo "— — — — — — — — — — —")"

    # CloudWatch SES utilization (last 60 min, 1-min resolution)
    start_cw=$(date -u -d '60 minutes ago' +%Y-%m-%dT%H:%M:%SZ)
    end_cw=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    ses_cw_json=$(aws cloudwatch get-metric-statistics \
      --namespace AWS/SES \
      --metric-name Send \
      --start-time "$start_cw" \
      --end-time "$end_cw" \
      --period 60 \
      --statistics Sum \
      --region "$AWS_REGION" \
      --output json 2>/dev/null || echo '{"Datapoints":[]}')
    read -r ses_util_avg ses_util_max <<< "$(echo "$ses_cw_json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
points = data.get('Datapoints', [])
try:
    max_rate = int('$ses_api_max_rate')
except:
    max_rate = 0
period = 60
if points and max_rate > 0:
    utils = [(p['Sum'] / (max_rate * period)) * 100 for p in points]
    print(f'{sum(utils)/len(utils):.1f} {max(utils):.1f}')
else:
    print('— —')
" 2>/dev/null || echo '— —')"

    # Track session peak utilization
    if [[ "$ses_util_max" =~ ^[0-9.]+$ ]]; then
      new_max=$(echo "$ses_util_max" | awk '{printf "%.0f", $1}')
      old_peak=$(echo "$ses_peak_util" | awk '{printf "%.0f", $1}')
      if (( new_max > old_peak )); then
        ses_peak_util="$ses_util_max"
      fi
    fi
  fi

  # ── Display ──
  printf "${B}═══════════════════════════════════════════════════════════════${N}\n"
  printf "${B}  MAUTIC CAMPAIGN MONITOR${N}   %s   (every %ss)\n" "$now" "$INTERVAL"
  printf "${B}═══════════════════════════════════════════════════════════════${N}\n"

  printf "\n${B}  SYSTEM${N}\n"
  printf "  CPU:       "; bar "$cpu_pct"; echo ""
  printf "  Memory:    "; bar "$mem_pct"; printf "  %s / %s MB\n" "$mem_used_mb" "$mem_total_mb"
  printf "  Swap:      %s MB\n" "$swap_used_mb"
  printf "  Disk:      "; bar "$disk_pct"; echo ""
  printf "  Load:      %s  %s  %s\n" "$load1" "$load5" "$load15"
  printf "  Disk I/O:  R: %s KB/s  W: %s KB/s\n" "$io_read_kbs" "$io_write_kbs"

  printf "\n${B}  QUEUES${N}\n"
  if [[ "$rabbit_email" =~ ^[0-9]+$ ]]; then
    est_mails=$(( rabbit_email * BATCH_SIZE ))
    printf "  RabbitMQ emails:   ${C}%s${N} msgs  (~${C}%s${N} mails)\n" "$rabbit_email" "$est_mails"
  else
    printf "  RabbitMQ emails:   ${C}%s${N} pending\n" "$rabbit_email"
  fi
  printf "  RabbitMQ hits:     ${C}%s${N} pending\n" "$rabbit_hit"
  printf "  Doctrine failed:   ${C}%s${N} pending\n" "$rabbit_failed"

  printf "\n${B}  PROCESSES${N}\n"
  printf "  Email workers:     ${C}%s${N}\n" "$worker_email"
  printf "  Hit workers:       ${C}%s${N}\n" "$worker_hit"
  printf "  Failed workers:    ${C}%s${N}\n" "$worker_failed"
  printf "  Campaign/Send:     ${C}%s${N}\n" "$campaign_procs"
  printf "  PHP-FPM pool:      ${C}%s${N}\n" "$php_fpm_count"

  printf "\n${B}  DATABASE${N}\n"
  printf "  Active threads:    ${C}%s${N}\n" "$db_threads"
  printf "  Queries/sec:       ${C}%s${N}\n" "$qps"

  printf "\n${B}  SES API (AWS)${N}  (refresh every %ss)\n" "$(( SES_REFRESH * INTERVAL ))"
  printf "  24h quota:         "
  if [[ "$ses_api_quota_pct" =~ ^[0-9]+$ ]]; then
    bar "$ses_api_quota_pct"
    printf "  %s / %s\n" "$ses_api_sent_24h" "$ses_api_24h_limit"
  else
    printf "${C}%s${N}\n" "$ses_api_quota_pct"
  fi
  if [[ -n "${bucket_rate:-}" ]]; then
    printf "  Max send rate:     ${C}%s${N} /sec  (DSN ratelimit: ${B}%s${N}, AWS limit: %s)\n" "$bucket_rate" "$bucket_rate" "$ses_api_max_rate"
  else
    printf "  Max send rate:     ${C}%s${N} /sec\n" "$ses_api_max_rate"
  fi
  printf "  Sent (1h):         ${C}%s${N}\n" "$ses_api_1h_sent"
  printf "  Sent (24h):        ${C}%s${N}\n" "$ses_api_24h_sent"
  printf "  Live rate (15m):   ${C}%s${N} /sec\n" "$ses_api_15m_rate"
  printf "  Utilization (60m): avg ${C}%s%%${N}  max ${C}%s%%${N}  peak ${C}%s%%${N}\n" "$ses_util_avg" "$ses_util_max" "$ses_peak_util"
  printf "  Token bucket:      %b" "$bucket_info"
  if [[ "$bucket_tokens" =~ ^[0-9.]+$ ]]; then
    if [[ "$bucket_pct" =~ ^[0-9]+$ ]]; then
      tb_color="$G"
      (( bucket_pct < 30 )) && tb_color="$Y"
      (( bucket_pct < 10 )) && tb_color="$R"
      printf "  ${tb_color}%s${N} / %s tokens (%s%%)" "$bucket_tokens" "$bucket_capacity" "$bucket_pct"
    else
      printf "  ${C}%s${N} tokens" "$bucket_tokens"
    fi
  fi
  echo ""

  # Bounce rate with color coding (AWS warns at 5%, suspends at 10%)
  if [[ "$ses_api_bounce_pct" =~ ^[0-9.]+$ ]]; then
    bounce_color="$G"
    bounce_val=$(echo "$ses_api_bounce_pct" | awk '{printf "%.0f", $1}')
    (( bounce_val >= 3 )) && bounce_color="$Y"
    (( bounce_val >= 5 )) && bounce_color="$R"
    printf "  Bounce rate:       ${bounce_color}%s%%${N}  (24h: %s bounces)\n" "$ses_api_bounce_pct" "$ses_api_24h_bounces"
  else
    printf "  Bounce rate:       ${C}%s${N}\n" "$ses_api_bounce_pct"
  fi

  # Complaint rate with color coding (AWS warns at 0.1%, suspends at 0.5%)
  if [[ "$ses_api_complaint_pct" =~ ^[0-9.]+$ ]]; then
    compl_color="$G"
    compl_val=$(echo "$ses_api_complaint_pct" | awk '{printf "%.0f", $1 * 10}')
    (( compl_val >= 1 )) && compl_color="$Y"   # >= 0.1%
    (( compl_val >= 5 )) && compl_color="$R"    # >= 0.5%
    printf "  Complaint rate:    ${compl_color}%s%%${N}  (24h: %s complaints)\n" "$ses_api_complaint_pct" "$ses_api_24h_complaints"
  else
    printf "  Complaint rate:    ${C}%s${N}\n" "$ses_api_complaint_pct"
  fi

  printf "  Rejects (1h):      ${C}%s${N}\n" "$ses_api_1h_rejects"

  printf "\n${B}═══════════════════════════════════════════════════════════════${N}\n"
  printf "  Press Ctrl+C to exit  |  Log: %s\n" "$LOG_FILE"
  tput ed          # clear any leftover lines from previous render

  # ── Log to CSV ──
  echo "$now,$cpu_pct,$mem_pct,$mem_used_mb,$swap_used_mb,$io_read_kbs,$io_write_kbs,$rabbit_email,$rabbit_hit,$rabbit_failed,$worker_count,$db_threads,$qps,$load1,$load5,$ses_api_1h_sent,$ses_api_24h_sent,$ses_api_24h_bounces,$ses_api_24h_complaints,$ses_api_24h_rejects,$ses_api_quota_pct,$ses_util_avg,$ses_util_max,$ses_peak_util" >> "$LOG_FILE"

  prev_ts=$ts_epoch
  iteration=$(( iteration + 1 ))
  sleep "$INTERVAL"
done
