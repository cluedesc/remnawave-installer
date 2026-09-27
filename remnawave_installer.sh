#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_VERSION="0.1.0"

PANEL_DIR="/opt/remnawave"
NODE_DIR="/opt/remnanode"

LOG_DIR="/var/log/remnawave-installer"
LOG_FILE="${LOG_DIR}/minimal-installer.log"

STATE_DIR="/etc/remnawave-installer"

PANEL_STATE_FILE="${STATE_DIR}/panel.env"
PANEL_AUTH_STATE_FILE="${STATE_DIR}/panel-auth.env"
SUPPORT_NOTICE_FILE="${STATE_DIR}/support-notice-shown"

BACKUP_ROOT="/var/backups/remnawave-installer"

WARP_NATIVE_DIR="/opt/warp-native"
WARP_CONF="/etc/wireguard/warp.conf"

PANEL_ADMIN_USERNAME=""
PANEL_ADMIN_PASSWORD=""

PANEL_AUTH_BASE=""
PANEL_AUTH_TOKEN=""

PANEL_AUTH_USERNAME=""
PANEL_AUTH_PASSWORD=""

# Keep both templates on the same v3 release; the compose image stays on :3.
PANEL_TEMPLATE_VERSION="3.4.4"
PANEL_COMPOSE_URL="https://raw.githubusercontent.com/remnawave/backend/${PANEL_TEMPLATE_VERSION}/docker-compose-prod.yml"
PANEL_ENV_URL="https://raw.githubusercontent.com/remnawave/backend/${PANEL_TEMPLATE_VERSION}/.env.sample"

CERTBOT_RENEW_CRON="# remnawave-installer certbot renew"

WAIT_REFRESH_INTERVAL=1
HTTP_CHECK_TIMEOUT=2

RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
MAGENTA='\033[1;35m'
CYAN='\033[1;36m'
GRAY='\033[0;90m'
RESET='\033[0m'

# SHARED BEGIN

log() {
  if [ -d "$LOG_DIR" ] && [ -w "$LOG_DIR" ]; then
    printf "%b\n" "$*" | tee -a "$LOG_FILE"
  else
    printf "%b\n" "$*"
  fi
}

log_file_append() {
  if [ -d "$LOG_DIR" ] && [ -w "$LOG_DIR" ]; then
    printf "%s\n" "$*" >> "$LOG_FILE"
  fi
}

log_file_block() {
  local title="$1"
  local file="$2"

  if [ -d "$LOG_DIR" ] && [ -w "$LOG_DIR" ]; then
    {
      printf "\n[%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$title"
      sed 's/\r$//' "$file"
    } >> "$LOG_FILE"
  fi
}

blank() { log ""; }

hr() { log "${GRAY}------------------------------------------------------------${RESET}"; }

section() {
  blank

  log "${GREEN}==>${RESET} $*"
}

step() { log "${GREEN}  -${RESET} $*"; }

info() { log "${GREEN}[+]${RESET} $*"; }

ok() { log "${GREEN}  [OK]${RESET} $*"; }

warn() { log "${YELLOW}[!]${RESET} $*"; }

note() { log "${YELLOW}  [!]${RESET} $*"; }

skip() { log "${GRAY}  [SKIP]${RESET} $*"; }

detail() { log "${GRAY}    $*${RESET}"; }

micro() { log "${GRAY}      $*${RESET}"; }

summary_item() {
  local key="$1"
  local value="$2"

  log "${GRAY}    ${key}:${RESET} ${value}"
}

die() {
  local message="${RED}[x]${RESET} $*"

  if [ -d "$LOG_DIR" ] && [ -w "$LOG_DIR" ]; then
    printf "%b\n" "$message" | tee -a "$LOG_FILE" >&2
  else
    printf "%b\n" "$message" >&2
  fi

  exit 1
}

prompt_line() {
  printf "%b" "${GREEN}  [?]${RESET} $*"
}

prompt_default() {
  printf "%b" "${GRAY}${1}${RESET}"
}

menu_title() {
  blank

  log "${GREEN}::${RESET} $*"
}

menu_item() {
  local key="$1"
  local label="$2"

  printf "%b\n" "${GRAY}   [${key}]${RESET} ${label}"
}

menu_item_accent() {
  local key="$1"
  local label="$2"

  printf "%b\n" "${MAGENTA}   [${key}]${RESET} ${CYAN}${label}${RESET}"
}

read_input() {
  local __read_input_value=""
  local __read_input_fd

  if { exec {__read_input_fd}</dev/tty; } 2>/dev/null; then
    IFS= read -r __read_input_value <&"$__read_input_fd" || { exec {__read_input_fd}<&-; return 130; }
    exec {__read_input_fd}<&-
  else
    IFS= read -r __read_input_value || return 130
  fi

  printf '%s' "$__read_input_value"
}

read_secret_input() {
  local __read_secret_input_value=""
  local __read_secret_input_fd

  if { exec {__read_secret_input_fd}</dev/tty; } 2>/dev/null; then
    IFS= read -r -s __read_secret_input_value <&"$__read_secret_input_fd" || { exec {__read_secret_input_fd}<&-; return 130; }
    exec {__read_secret_input_fd}<&-
  else
    IFS= read -r -s __read_secret_input_value || return 130
  fi

  printf '%s' "$__read_secret_input_value"
}

print_indented_file() {
  local file="$1"

  printf "%b\n" "${GRAY}    |-- output${RESET}"
  tr '\r' '\n' < "$file" | sed '/^[[:space:]]*$/d; s/^/    | /'
  printf "%b\n" "${GRAY}    |-- end${RESET}"
}

run_cmd() {
  local description="$1"

  shift

  local output_file
  local exit_code

  output_file="$(mktemp)"

  step "$description"

  log_file_append ""
  log_file_append "[$(date '+%Y-%m-%d %H:%M:%S')] RUN: $*"

  if "$@" >"$output_file" 2>&1; then
    exit_code=0
  else
    exit_code=$?
  fi

  if [ "$exit_code" -eq 0 ]; then
    log_file_block "OUTPUT: $description" "$output_file"

    if [ -s "$output_file" ]; then
      print_indented_file "$output_file"
    fi

    rm -f "$output_file"

    ok "$description"

    return 0
  fi

  log_file_block "FAILED (${exit_code}): $description" "$output_file"

  warn "$description failed with exit code ${exit_code}."

  if [ -s "$output_file" ]; then
    print_indented_file "$output_file"
  fi

  rm -f "$output_file"

  return "$exit_code"
}

run_cmd_stream() {
  local description="$1"

  shift

  local -a cmd=("$@")

  local output_file
  local exit_code
  local -a pipeline_status
  local pipeline_code

  case "${cmd[0]}" in
    apt|apt-get)
      cmd=(
        env
        DEBIAN_FRONTEND=noninteractive
        APT_LISTCHANGES_FRONTEND=none
        NEEDRESTART_MODE=a
        "${cmd[0]}"
        -o Dpkg::Use-Pty=0
        -o Dpkg::Progress-Fancy=0
        -o Apt::Color=0
        -o APT::Color=0
        "${cmd[@]:1}"
      )
      ;;
  esac

  output_file="$(mktemp)"

  step "$description"

  log_file_append ""
  log_file_append "[$(date '+%Y-%m-%d %H:%M:%S')] RUN: ${cmd[*]}"

  if [ -d "$LOG_DIR" ] && [ -w "$LOG_DIR" ]; then
    printf "%b\n" "${GRAY}    |-- output${RESET}"

    if "${cmd[@]}" 2>&1 | tr '\r' '\n' | sed '/^[[:space:]]*$/d' | tee "$output_file" | tee -a "$LOG_FILE" | sed 's/^/    | /'; then
      pipeline_status=("${PIPESTATUS[@]}")
    else
      pipeline_status=("${PIPESTATUS[@]}")
    fi

    printf "%b\n" "${GRAY}    |-- end${RESET}"
  else
    printf "%b\n" "${GRAY}    |-- output${RESET}"

    if "${cmd[@]}" 2>&1 | tr '\r' '\n' | sed '/^[[:space:]]*$/d' | tee "$output_file" | sed 's/^/    | /'; then
      pipeline_status=("${PIPESTATUS[@]}")
    else
      pipeline_status=("${PIPESTATUS[@]}")
    fi

    printf "%b\n" "${GRAY}    |-- end${RESET}"
  fi

  exit_code=0
  for pipeline_code in "${pipeline_status[@]}"; do
    if [ "$pipeline_code" -ne 0 ]; then
      exit_code="$pipeline_code"
      break
    fi
  done

  if [ "$exit_code" -eq 0 ]; then
    rm -f "$output_file"

    ok "$description"

    return 0
  fi

  log_file_append "[$(date '+%Y-%m-%d %H:%M:%S')] FAILED (${exit_code}): $description"

  warn "$description failed with exit code ${exit_code}."

  rm -f "$output_file"

  return "$exit_code"
}

need_root() {
  if [ "${EUID}" -ne 0 ]; then
    die "This script must be run as root."
  fi
}

check_os() {
  if [ ! -f /etc/os-release ]; then
    die "Error: /etc/os-release was not found."
  fi

  . /etc/os-release

  if [ "${ID:-}" != "ubuntu" ]; then
    die "This installer supports Ubuntu only. Current OS: ${PRETTY_NAME:-unknown}."
  fi
}

prepare_log() {
  mkdir -p "$LOG_DIR"

  touch "$LOG_FILE"

  chmod 600 "$LOG_FILE"
}

ask() {
  local __ask_prompt="$1"
  local __ask_var_name="$2"
  local __ask_default_value="${3:-}"

  local __ask_value=""

  if [ -n "$__ask_default_value" ]; then
    prompt_line "$__ask_prompt "
    prompt_default "[$__ask_default_value]"

    printf ": "

    __ask_value="$(read_input)" || return 130

    __ask_value="${__ask_value:-$__ask_default_value}"
  else
    prompt_line "$__ask_prompt: "

    __ask_value="$(read_input)" || return 130
  fi

  __ask_value="$(printf "%s" "$__ask_value" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"

  printf -v "$__ask_var_name" '%s' "$__ask_value"
}

ask_secret() {
  local __ask_secret_prompt="$1"
  local __ask_secret_var_name="$2"
  local __ask_secret_show_empty_note="${3:-1}"

  local __ask_secret_value=""

  prompt_line "$__ask_secret_prompt: "

  __ask_secret_value="$(read_secret_input)" || { printf "\n"; return 130; }

  printf "\n"

  __ask_secret_value="$(printf "%s" "$__ask_secret_value" | tr -d '\r')"

  if [ -n "$__ask_secret_value" ]; then
    micro "input hidden"
  elif [ "$__ask_secret_show_empty_note" = "1" ]; then
    note "Secret value is empty."
  fi

  printf -v "$__ask_secret_var_name" '%s' "$__ask_secret_value"
}

ask_required() {
  local __ask_required_prompt="$1"
  local __ask_required_var_name="$2"
  local __ask_required_value=""

  while true; do
    if [ "$#" -ge 3 ]; then
      ask "$__ask_required_prompt" __ask_required_value "$3" || return 130
    else
      ask "$__ask_required_prompt" __ask_required_value || return 130
    fi

    if [ -n "$__ask_required_value" ]; then
      printf -v "$__ask_required_var_name" '%s' "$__ask_required_value"

      return 0
    fi

    warn "${__ask_required_prompt} cannot be empty. Please try again."
  done
}

ask_secret_required() {
  local __ask_secret_required_prompt="$1"
  local __ask_secret_required_var_name="$2"
  local __ask_secret_required_value=""

  while true; do
    ask_secret "$__ask_secret_required_prompt" __ask_secret_required_value 0 || return 130

    if [ -n "$__ask_secret_required_value" ]; then
      printf -v "$__ask_secret_required_var_name" '%s' "$__ask_secret_required_value"

      return 0
    fi

    warn "${__ask_secret_required_prompt} cannot be empty. Please try again."
  done
}

ask_validated() {
  local __ask_validated_value=""
  while true; do
    ask "$1" __ask_validated_value "${5:-}" || return 130
    if "$3" "$__ask_validated_value"; then
      printf -v "$2" '%s' "$__ask_validated_value"
      return 0
    fi
    warn "$4 Please try again."
  done
}

ask_choice() {
  local __ask_choice_value=""
  while true; do
    ask "$1" __ask_choice_value "${5:-}" || return 130
    if [[ "$__ask_choice_value" =~ ^[0-9]+$ ]]; then
      # Strip zeroes before arithmetic so input is decimal and cannot overflow.
      while [[ "$__ask_choice_value" == 0?* ]]; do __ask_choice_value="${__ask_choice_value#0}"; done
      if [ "${#__ask_choice_value}" -le 9 ] &&
         [ "$__ask_choice_value" -ge "$3" ] && [ "$__ask_choice_value" -le "$4" ]; then
        printf -v "$2" '%s' "$__ask_choice_value"
        return 0
      fi
    fi
    warn "Enter a number from $3 to $4."
  done
}

confirm() {
  local prompt="$1"
  local answer=""
  local normalized=""

  prompt_line "$prompt "
  prompt_default "[y/N]"

  printf ": "

  answer="$(read_input)" || return 130

  normalized="$(printf "%s" "$answer" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | tr '[:upper:]' '[:lower:]')"

  log_file_append "[$(date '+%Y-%m-%d %H:%M:%S')] CONFIRM: ${prompt} => ${normalized:-<empty>}"

  case "$normalized" in
    y|yes|$'\u0434'|$'\u0434\u0430') return 0 ;;
    *) return 1 ;;
  esac
}

ask_menu_choice() {
  local __ask_menu_choice_var_name="$1"
  
  local __ask_menu_choice_value=""

  prompt_line "Selection: "
  __ask_menu_choice_value="$(read_input)" || return 130
  __ask_menu_choice_value="$(printf "%s" "$__ask_menu_choice_value" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"

  printf -v "$__ask_menu_choice_var_name" '%s' "$__ask_menu_choice_value"
}

ask_delete_confirmation() {
  local __ask_delete_confirmation_var_name="$1"

  local __ask_delete_confirmation_value=""

  prompt_line "Type DELETE to confirm: "
  __ask_delete_confirmation_value="$(read_input)" || return 130
  __ask_delete_confirmation_value="$(printf "%s" "$__ask_delete_confirmation_value" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"

  printf -v "$__ask_delete_confirmation_var_name" '%s' "$__ask_delete_confirmation_value"
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

random_hex() {
  openssl rand -hex "$1"
}

random_username() {
  printf 'admin%s' "$(openssl rand -hex 3)"
}

random_password() {
  local upper
  local lower
  local digit
  local rest=""

  while [ -z "${upper:-}" ]; do
    upper="$(openssl rand -base64 24 | LC_ALL=C tr -dc 'A-Z' | head -c 1)"
  done

  while [ -z "${lower:-}" ]; do
    lower="$(openssl rand -base64 24 | LC_ALL=C tr -dc 'a-z' | head -c 1)"
  done

  while [ -z "${digit:-}" ]; do
    digit="$(openssl rand -base64 24 | LC_ALL=C tr -dc '0-9' | head -c 1)"
  done

  while [ "${#rest}" -lt 29 ]; do
    rest="${rest}$(openssl rand -base64 96 | LC_ALL=C tr -dc 'A-Za-z0-9')"
    rest="${rest:0:29}"
  done

  printf '%s%s%s%s' "$upper" "$lower" "$digit" "$rest"
}

validate_admin_password() {
  local password="$1"

  [ "${#password}" -ge 24 ] || return 1
  [[ "$password" =~ [A-Z] ]] || return 1
  [[ "$password" =~ [a-z] ]] || return 1
  [[ "$password" =~ [0-9] ]] || return 1
}

set_env_value() {
  local file="$1"
  local key="$2"
  local value="$3"

  local escaped

  escaped=$(printf '%s' "$value" | sed -e 's/[\/&]/\\&/g')

  if grep -q "^${key}=" "$file"; then
    sed -i "s/^${key}=.*/${key}=${escaped}/" "$file"
  else
    if [ -s "$file" ] && [ -n "$(tail -c 1 "$file")" ]; then
      printf '\n' >> "$file"
    fi
    printf '%s=%s\n' "$key" "$value" >> "$file"
  fi
}

shell_quote() {
  local value="$1"

  printf '%q' "$value"
}

is_ipv4() {
  local ip="$1"

  local a b c d

  local octet

  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1

  IFS=. read -r a b c d <<< "$ip"

  for octet in "$a" "$b" "$c" "$d"; do
    [[ "$octet" =~ ^[0-9]+$ ]] || return 1
    [ "$octet" -le 255 ] || return 1
  done
}

validate_domain() {
  local domain="$1"

  local label

  local -a labels

  [ -n "$domain" ] || return 1
  [ "${#domain}" -le 253 ] || return 1
  [[ "$domain" != *"/"* ]] || return 1
  [[ "$domain" != .* && "$domain" != *. ]] || return 1
  [[ "$domain" == *.* ]] || return 1
  [[ ! "$domain" =~ ^[0-9.]+$ ]] || return 1

  IFS=. read -ra labels <<< "$domain"

  for label in "${labels[@]}"; do
    [ -n "$label" ] || return 1
    [ "${#label}" -le 63 ] || return 1
    [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
  done
}

validate_port() {
  local port="$1"

  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  while [[ "$port" == 0?* ]]; do port="${port#0}"; done
  [ "${#port}" -le 5 ] || return 1
  [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

validate_optional_ipv4() {
  [ -z "$1" ] || is_ipv4 "$1"
}

validate_host() {
  local host="$1"

  is_ipv4 "$host" || validate_domain "$host"
}

assert_managed_dir() {
  local dir="$1"

  case "$dir" in
    "$PANEL_DIR"|"$NODE_DIR") return 0 ;;
    *) die "Refusing to remove unexpected directory: ${dir}" ;;
  esac
}

# SHARED END

# PACKAGES BEGIN

install_base_packages() {
  section "Base packages"

  run_cmd_stream "Update apt package index" apt-get update

  run_cmd_stream "Install required base packages" apt-get install -y ca-certificates curl gnupg openssl jq ufw logrotate apt-transport-https lsb-release dnsutils
}

install_docker() {
  if command_exists docker && docker compose version >/dev/null 2>&1; then
    ok "Docker and Docker Compose are already installed."

    return 0
  fi

  section "Docker"

  install -m 0755 -d /etc/apt/keyrings
  run_cmd_stream "Install Docker apt repository key" bash -c 'curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --yes --dearmor -o /etc/apt/keyrings/docker.gpg'
  chmod a+r /etc/apt/keyrings/docker.gpg

  local codename

  codename="$(. /etc/os-release && echo "${VERSION_CODENAME}")"

  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${codename} stable" > /etc/apt/sources.list.d/docker.list

  run_cmd_stream "Update apt package index for Docker" apt-get update

  run_cmd_stream "Install Docker packages" apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  run_cmd "Enable and start Docker" systemctl enable --now docker

  run_cmd "Verify Docker daemon" bash -c 'docker info >/dev/null'
}

install_prerequisites() {
  install_base_packages

  install_docker
}

# PACKAGES END

# DNS BEGIN

get_public_ipv4() {
  curl -fsS -4 https://api.ipify.org 2>/dev/null || curl -fsS -4 https://ifconfig.me 2>/dev/null || true
}

ipv4_to_int() {
  local ip="$1"

  local a b c d

  is_ipv4 "$ip" || return 1

  IFS=. read -r a b c d <<< "$ip"

  echo $(( (a << 24) + (b << 16) + (c << 8) + d ))
}

ip_in_cidr() {
  local ip="$1"
  local cidr="$2"

  local network mask ip_int net_int mask_int

  network="${cidr%/*}"
  mask="${cidr#*/}"

  ip_int="$(ipv4_to_int "$ip")"
  net_int="$(ipv4_to_int "$network")"

  mask_int=$(( 0xFFFFFFFF << (32 - mask) & 0xFFFFFFFF ))

  [ $(( ip_int & mask_int )) -eq $(( net_int & mask_int )) ]
}

is_cloudflare_ipv4() {
  local ip="$1"

  local ranges
  local cidr

  ranges="$(curl -fsS https://www.cloudflare.com/ips-v4 2>/dev/null || true)"

  [ -n "$ranges" ] || return 1

  while read -r cidr; do
    [ -n "$cidr" ] || continue

    if ip_in_cidr "$ip" "$cidr"; then
      return 0
    fi

  done <<< "$ranges"

  return 1
}

resolve_domain_ipv4() {
  local domain="$1"

  local resolver
  local attempt
  local result

  local all_results

  for attempt in 1 2 3; do
    all_results=""

    for resolver in "" "@1.1.1.1" "@8.8.8.8" "@9.9.9.9"; do
      result="$(dig +time=2 +tries=1 +short A "$domain" $resolver 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)"

      if [ -n "$result" ]; then
        all_results="${all_results}
${result}"
      fi
    done

    if [ -n "$(printf '%s\n' "$all_results" | sed '/^[[:space:]]*$/d')" ]; then
      printf '%s\n' "$all_results" | sed '/^[[:space:]]*$/d' | sort -u
      
      return 0
    fi

    sleep 2
  done
}

check_domain_dns() {
  local domain="$1"

  local server_ip
  local domain_ips

  server_ip="$(get_public_ipv4)"

  domain_ips="$(resolve_domain_ipv4 "$domain" || true)"

  if [ -z "$server_ip" ]; then
    warn "Warning: public server IPv4 could not be detected."

    return 0
  fi

  if [ -z "$domain_ips" ]; then
    warn "Warning: DNS A record was not found for ${domain}."

    confirm "Continue without a successful DNS check?" || return 130

    return 0
  fi

  if printf '%s\n' "$domain_ips" | grep -Fxq "$server_ip"; then
    ok "DNS check passed: ${domain} -> ${server_ip}."

    return 0
  fi

  local ip

  for ip in $domain_ips; do
    if is_cloudflare_ipv4 "$ip"; then
      warn "DNS ${domain} resolves to Cloudflare IP ${ip}."

      confirm "Continue with Cloudflare proxy enabled?" || return 130

      return 0
    fi
  done

  warn "DNS ${domain} currently resolves to: $(printf '%s' "$domain_ips" | tr '\n' ' ')"

  warn "Public server IPv4: ${server_ip}"

  confirm "Continue? TLS issuance may fail." || return 130
}

# DNS END

# BACKUP_RESTORE BEGIN

backup_path() {
  local path="$1" name="$2" dest
  dest="${BACKUP_ROOT}/${name}-$(date +%Y%m%d%H%M%S)"
  if [ -e "$path" ]; then
    mkdir -p "$dest" && chmod 700 "$dest" && cp -a "$path" "$dest/" || return 1
    ok "Backup: ${path} -> ${dest}/"
  fi
}

backup_compose() (
  local dir="$1"
  shift
  cd "$dir" || return 1
  local files=(-f docker-compose.yml)
  [ ! -f docker-compose.subscription.yml ] || files+=(-f docker-compose.subscription.yml)
  docker compose "${files[@]}" "$@"
)

backup_wait_database() {
  local attempt
  for attempt in {1..30}; do
    if backup_compose "$PANEL_DIR" exec -T remnawave-db sh -c \
      'pg_isready -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-postgres}"' >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  warn "Database did not become ready."
  return 1
}

backup_panel() {
  backup_all
}

backup_node() {
  backup_path "$NODE_DIR/docker-compose.yml" "node-compose" || return 1
  backup_path "$NODE_DIR/.env" "node-env"
}

backup_all() (
  umask 077
  mkdir -p "$BACKUP_ROOT" || return 1
  local stage archive path running_services has_panel=0 started_database=0
  stage="$(mktemp -d "${BACKUP_ROOT}/.backup.XXXXXX")" || return 1
  backup_release_database() {
    if [ "$started_database" = 1 ]; then
      backup_compose "$PANEL_DIR" stop remnawave-db || {
        warn "Could not return the database to its stopped state."; return 1;
      }
      started_database=0
    fi
  }
  backup_cleanup() {
    local status="$1"
    backup_release_database || status=1
    rm -rf -- "$stage" || status=1
    exit "$status"
  }
  trap 'backup_cleanup $?' EXIT
  archive="${BACKUP_ROOT}/remnawave-backup-$(date +%Y%m%d%H%M%S)-${stage##*.}.tar.gz"
  local paths=()
  for path in "$PANEL_DIR" "$NODE_DIR" "$STATE_DIR" /etc/caddy/Caddyfile /etc/nginx/conf.d/remnawave-panel.conf /etc/nginx/conf.d/remnawave-subscription-page.conf; do
    [ ! -e "$path" ] || paths+=("${path#/}")
  done
  [ "${#paths[@]}" -gt 0 ] || { warn "Nothing to back up."; return 1; }
  if [ -d "$PANEL_DIR" ]; then
    [ -f "$PANEL_DIR/.env" ] && [ -f "$PANEL_DIR/docker-compose.yml" ] || {
      warn "Panel configuration is incomplete; backup aborted."; return 1;
    }
    running_services="$(backup_compose "$PANEL_DIR" ps --status running --services)" || return 1
    if ! grep -Fxq remnawave-db <<< "$running_services"; then
      # Start only PostgreSQL; never start application writers to make a backup.
      started_database=1
      backup_compose "$PANEL_DIR" up -d --no-deps remnawave-db || return 1
    fi
    backup_wait_database || return 1
    # pg_dump uses one consistent PostgreSQL snapshot; keep binary stdout untouched.
    backup_compose "$PANEL_DIR" exec -T remnawave-db sh -c \
      'exec pg_dump -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-postgres}" --format=custom --create' \
      > "$stage/database.dump" || { warn "Database dump failed; no backup created."; return 1; }
    [ -s "$stage/database.dump" ] || return 1
    has_panel=1
  fi
  printf 'remnawave-v3-backup-1\npanel=%s\n' "$has_panel" > "$stage/manifest"
  tar -czf "$stage/files.tar.gz" -C / -- "${paths[@]}" || {
    warn "Configuration archive failed; no backup created."; return 1;
  }
  backup_validate_files "$stage/files.tar.gz" "$stage" || {
    warn "Configuration contains unsupported links or paths; no backup created."; return 1;
  }
  local members=(manifest files.tar.gz)
  [ "$has_panel" = 0 ] || members+=(database.dump)
  tar -czf "$stage/archive.tar.gz" -C "$stage" -- "${members[@]}" || return 1
  backup_release_database || return 1
  mv -- "$stage/archive.tar.gz" "$archive" || return 1
  ok "Backup archive: ${archive}"
)

# Only regular files and directories under our configuration roots are restorable.
# Reject links and traversal before extraction, including links in live parent paths.
backup_validate_files() {
  local archive="$1" name root allowed component current
  tar -tzf "$archive" > "$2/names" && tar -tvzf "$archive" > "$2/types" || return 1
  while IFS= read -r name; do
    case "${name:0:1}" in -|d) ;; *) return 1 ;; esac
  done < "$2/types"
  while IFS= read -r name; do
    case "$name" in ''|/*|*\\*|../*|*/../*|*/..|./*|*/./*) return 1 ;; esac
    allowed=0
    for root in "${PANEL_DIR#/}" "${NODE_DIR#/}" "${STATE_DIR#/}"; do
      case "$name" in "$root"|"$root/"*) allowed=1 ;; esac
    done
    case "$name" in etc/caddy/Caddyfile|etc/nginx/conf.d/remnawave-panel.conf|etc/nginx/conf.d/remnawave-subscription-page.conf) allowed=1 ;; esac
    [ "$allowed" = 1 ] || return 1
    current=""
    local components=()
    IFS=/ read -r -a components <<< "$name"
    for component in "${components[@]}"; do
      current="$current/$component"
      [ ! -L "$current" ] || return 1
    done
  done < "$2/names"
}

restore_backup() (
  local archive stage name has_panel
  while true; do
    ask_required "Backup .tar.gz path" archive || return $?
    [ ! -f "$archive" ] || break
    warn "Backup was not found: ${archive}. Enter an existing archive path."
  done
  umask 077
  stage="$(mktemp -d)" || return 1
  trap 'rm -rf -- "$stage"' EXIT
  tar -tzf "$archive" > "$stage/members" && tar -tvzf "$archive" > "$stage/types" || return 1
  while IFS= read -r name; do
    case "$name" in manifest|files.tar.gz|database.dump) ;; *) warn "Unsupported or unsafe backup."; return 1 ;; esac
  done < "$stage/members"
  while IFS= read -r name; do
    [ "${name:0:1}" = - ] || return 1
  done < "$stage/types"
  [ "$(sort "$stage/members" | uniq -d | wc -l)" -eq 0 ] || return 1
  tar -xzf "$archive" -C "$stage" --no-same-owner || return 1
  case "$(cat "$stage/manifest")" in
    $'remnawave-v3-backup-1\npanel=1') has_panel=1 ;;
    $'remnawave-v3-backup-1\npanel=0') has_panel=0 ;;
    *) warn "Unsupported backup format; a complete V3 backup is required."; return 1 ;;
  esac
  backup_validate_files "$stage/files.tar.gz" "$stage" || { warn "Unsafe configuration archive."; return 1; }
  if [ "$has_panel" = 1 ]; then
    grep -Fxq "${PANEL_DIR#/}/.env" "$stage/names" &&
      grep -Fxq "${PANEL_DIR#/}/docker-compose.yml" "$stage/names" &&
      [ -s "$stage/database.dump" ] || return 1
    # Resolve the saved DB image without starting the stack or mounting its data.
    # This also works when the old installation is stopped or no longer exists.
    mkdir "$stage/config" || return 1
    tar -xzf "$stage/files.tar.gz" -C "$stage/config" --no-same-owner || return 1
    local database_image
    database_image="$(backup_compose "$stage/config/${PANEL_DIR#/}" config --format json |
      jq -er '.services["remnawave-db"].image | select(type == "string" and length > 0)')" || return 1
    # No implicit pull before confirmation: use the saved PostgreSQL image locally.
    docker run --rm -i --pull=never --network none --entrypoint pg_restore "$database_image" --list \
      < "$stage/database.dump" >/dev/null || {
        warn "Dump validation failed. Ensure the saved database image is available locally: ${database_image}"; return 1;
      }
  elif grep -Eq "^${PANEL_DIR#/}(/|$)" "$stage/names"; then
    warn "Panel restore requires a database dump."; return 1
  fi
  warn "Restore replaces saved configuration and the Panel database. A failed restore leaves services stopped."
  confirm "Continue restore?" || { warn "Restore cancelled by user."; return 0; }
  # Stop all writers using the CURRENT compose before replacing it.
  if [ -f "$NODE_DIR/docker-compose.yml" ]; then
    backup_compose "$NODE_DIR" stop || return 1
  fi
  if [ "$has_panel" = 1 ] && [ -f "$PANEL_DIR/docker-compose.yml" ]; then
    backup_compose "$PANEL_DIR" stop || return 1
  fi
  if [ "$has_panel" = 1 ] && ! grep -Fxq "${PANEL_DIR#/}/docker-compose.subscription.yml" "$stage/names"; then
    rm -f -- "$PANEL_DIR/docker-compose.subscription.yml" || return 1
  fi
  tar -xzf "$stage/files.tar.gz" -C / --no-same-owner || return 1
  if [ "$has_panel" = 1 ]; then
    backup_compose "$PANEL_DIR" up -d --no-deps remnawave-db || return 1
    backup_wait_database || return 1
    # Recreate the database, removing tables introduced after this backup as well.
    backup_compose "$PANEL_DIR" exec -T remnawave-db sh -c \
      'exec pg_restore -U "${POSTGRES_USER:-postgres}" --dbname=template1 --clean --if-exists --create --exit-on-error' \
      < "$stage/database.dump" || { warn "Database restore failed; services remain stopped."; return 1; }
    start_panel_stack || return 1
  fi
  if [ -f "$NODE_DIR/docker-compose.yml" ]; then
    backup_compose "$NODE_DIR" up -d || return 1
  fi
  ok "Backup restored."
)

# BACKUP_RESTORE END

# PANEL_STATE BEGIN

save_panel_state() {
  local panel_domain="$1"
  local webserver="$2"
  local email="$3"
  local subscription_domain="${4:-}"

  mkdir -p "$STATE_DIR"
  
  chmod 700 "$STATE_DIR"
  
  cat > "$PANEL_STATE_FILE" <<EOF
PANEL_DOMAIN=$(shell_quote "$panel_domain")
WEBSERVER=$(shell_quote "$webserver")
LETSENCRYPT_EMAIL=$(shell_quote "$email")
SUBSCRIPTION_DOMAIN=$(shell_quote "$subscription_domain")
EOF

  chmod 600 "$PANEL_STATE_FILE"
}

load_panel_state() {
  if [ -f "$PANEL_STATE_FILE" ]; then
    # shellcheck disable=SC1090
    . "$PANEL_STATE_FILE"
  fi
}

save_panel_auth_state() {
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"

  cat > "$PANEL_AUTH_STATE_FILE" <<EOF
PANEL_AUTH_BASE=$(shell_quote "$PANEL_AUTH_BASE")
PANEL_AUTH_TOKEN=$(shell_quote "$PANEL_AUTH_TOKEN")
PANEL_AUTH_USERNAME=$(shell_quote "$PANEL_AUTH_USERNAME")
PANEL_AUTH_PASSWORD=$(shell_quote "$PANEL_AUTH_PASSWORD")
EOF

  chmod 600 "$PANEL_AUTH_STATE_FILE"
}

load_panel_auth_state() {
  if [ -f "$PANEL_AUTH_STATE_FILE" ]; then
    # shellcheck disable=SC1090
    . "$PANEL_AUTH_STATE_FILE"
  fi
}

remember_panel_auth() {
  local panel_base="${1:-}"
  local api_token="${2:-}"
  local username="${3:-}"
  local password="${4:-}"

  load_panel_auth_state

  [ -n "$panel_base" ] && PANEL_AUTH_BASE="$panel_base"
  [ -n "$api_token" ] && PANEL_AUTH_TOKEN="$api_token"
  [ -n "$username" ] && PANEL_AUTH_USERNAME="$username"
  [ -n "$password" ] && PANEL_AUTH_PASSWORD="$password"

  save_panel_auth_state
}

clear_panel_auth_token() {
  load_panel_auth_state
  PANEL_AUTH_TOKEN=""
  save_panel_auth_state
}

default_panel_api_base() {
  load_panel_state
  load_panel_auth_state

  if [ -n "${PANEL_AUTH_BASE:-}" ]; then
    printf "%s" "$PANEL_AUTH_BASE"

    return 0
  fi

  if [ "${WEBSERVER:-}" = "none" ]; then
    printf 'http://127.0.0.1:3000'
    return 0
  fi

  if [ -n "${PANEL_DOMAIN:-}" ]; then
    printf "https://%s" "$PANEL_DOMAIN"
  else
    printf "https://panel.example.com"
  fi
}

default_subscription_domain() {
  local panel_domain="$1"
  local suffix

  if [[ "$panel_domain" == *.*.* ]]; then
    suffix="${panel_domain#*.}"
    printf "sub.%s" "$suffix"
  elif [ -n "$panel_domain" ]; then
    printf "sub.%s" "$panel_domain"
  else
    printf "sub.example.com"
  fi
}

# PANEL_STATE END

# REVERSE_PROXY BEGIN

open_web_ports_if_needed() {
  if command_exists ufw && ufw status | grep -q "Status: active"; then
    local ufw_status

    local -a missing_ports=()

    ufw_status="$(ufw status)"

    if ! printf '%s\n' "$ufw_status" | grep -Eq '^80/tcp[[:space:]]+ALLOW[[:space:]]+'; then
      missing_ports+=(80/tcp)
    fi

    if ! printf '%s\n' "$ufw_status" | grep -Eq '^443/tcp[[:space:]]+ALLOW[[:space:]]+'; then
      missing_ports+=(443/tcp)
    fi

    if [ "${#missing_ports[@]}" -eq 0 ]; then
      ok "UFW already allows 80/tcp and 443/tcp."

      return 0
    fi

    if ! printf '%s\n' "$ufw_status" | grep -Eq '^(22/tcp|OpenSSH)[[:space:]]+ALLOW[[:space:]]+'; then
      warn "SSH is not allowed in UFW. If this is a remote server, you may lose access after firewall changes."
    fi

    if confirm "UFW is active. Open missing web ports (${missing_ports[*]})?"; then
      local port

      for port in "${missing_ports[@]}"; do
        run_cmd "Allow ${port} in UFW" ufw allow "$port"
      done

      run_cmd "Reload UFW" ufw reload
      
      run_cmd_stream "Show UFW status" ufw status verbose
    else
      warn "Ports 80/443 were not opened. Certificates and external access may not work."
    fi
  fi
}

install_caddy() {
  if command_exists caddy; then
    ok "Caddy is already installed."

    run_cmd "Ensure Caddy service is enabled" systemctl enable --now caddy || true

    return 0
  fi

  section "Caddy"

  run_cmd_stream "Install Caddy repository prerequisites" apt-get install -y debian-keyring debian-archive-keyring

  run_cmd_stream "Install Caddy apt repository key" bash -c "curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --yes --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg"
  run_cmd "Install Caddy apt source list" bash -c "curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list"

  run_cmd_stream "Update apt package index for Caddy" apt-get update

  run_cmd_stream "Install Caddy" apt-get install -y caddy
  
  run_cmd "Enable and start Caddy" systemctl enable --now caddy
}

caddy_global_email() {
  local caddyfile="$1"

  awk '
    /^[[:space:]]*($|#)/ && seen != 1 { next }
    seen != 1 {
      seen=1
      if ($0 !~ /^[[:space:]]*\{[[:space:]]*$/) { exit }
      in_global=1
      depth=1
      next
    }
    in_global == 1 {
      if ($0 ~ /^[[:space:]]*email[[:space:]]+/) {
        sub(/^[[:space:]]*email[[:space:]]+/, "", $0)
        print $0
        exit
      }
      if ($0 ~ /\{[[:space:]]*$/) { depth++ }
      if ($0 ~ /^[[:space:]]*\}/) {
        depth--
        if (depth == 0) { exit }
      }
    }
  ' "$caddyfile"
}

caddy_has_top_global_block() {
  local caddyfile="$1"

  awk '
    /^[[:space:]]*($|#)/ { next }
    /^[[:space:]]*\{[[:space:]]*$/ { found=1 }
    { exit }
    END {
      if (found) { exit 0 }
      exit 1
    }
  ' "$caddyfile"
}

is_placeholder_email() {
  case "$1" in
    ""|admin@example.com|example@example.com|email@example.com|user@example.com|you@example.com|your@email|your@email.com)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

ensure_caddy_global_email() {
  local caddyfile="$1"
  local desired_email="$2"

  local current_email
  local tmp_file

  [ -n "$desired_email" ] || return 0

  current_email="$(caddy_global_email "$caddyfile" || true)"

  if [ "$current_email" = "$desired_email" ]; then
    ok "Caddy global block already contains email ${current_email}."

    return 0
  fi

  if [ -n "$current_email" ] && ! is_placeholder_email "$current_email"; then
    warn "Caddy global block already contains email: ${current_email}"

    if ! confirm "Replace it with ${desired_email}?"; then
      detail "Keeping current Caddy email: ${current_email}."

      return 0
    fi
  elif [ -n "$current_email" ]; then
    detail "Replacing placeholder Caddy email ${current_email} with ${desired_email}."
  else
    detail "Adding email ${desired_email} to the Caddy global block."
  fi

  tmp_file="$(mktemp)"

  if caddy_has_top_global_block "$caddyfile"; then
    awk -v email="$desired_email" -v had_email="$([ -n "$current_email" ] && printf 1 || printf 0)" '
      BEGIN { in_global=0; done=0; depth=0 }
      in_global == 0 && done == 0 && $0 ~ /^[[:space:]]*\{[[:space:]]*$/ {
        in_global=1
        depth=1
        print
        if (had_email != 1) {
          printf "\temail %s\n", email
          done=1
        }
        next
      }
      in_global == 1 && had_email == 1 && done == 0 && $0 ~ /^[[:space:]]*email[[:space:]]+/ {
        printf "\temail %s\n", email
        done=1
        next
      }
      in_global == 1 && $0 ~ /\{[[:space:]]*$/ { depth++ }
      in_global == 1 && $0 ~ /^[[:space:]]*\}/ {
        depth--
        if (depth == 0) { in_global=0 }
      }
      { print }
    ' "$caddyfile" > "$tmp_file"
  else
    {
      printf "{\n\temail %s\n}\n\n" "$desired_email"

      cat "$caddyfile"
    } > "$tmp_file"
  fi

  install -o root -g caddy -m 640 "$tmp_file" "$caddyfile"

  rm -f "$tmp_file"
}

configure_caddy_panel() {
  local panel_domain="$1"
  local email="$2"

  local caddyfile="/etc/caddy/Caddyfile"

  local tmp_file

  install_caddy

  mkdir -p /etc/caddy /var/log/caddy
  chown -R caddy:caddy /var/log/caddy || true
  touch /var/log/caddy/remnawave-panel.access.log
  chown caddy:caddy /var/log/caddy/remnawave-panel.access.log || true
  chmod 640 /var/log/caddy/remnawave-panel.access.log || true

  [ -f "$caddyfile" ] || touch "$caddyfile"

  cp "$caddyfile" "${caddyfile}.bak.$(date +%Y%m%d%H%M%S)"

  ensure_caddy_global_email "$caddyfile" "$email"

  tmp_file="$(mktemp)"

  awk '
    /^# BEGIN REMNAWAVE PANEL$/ { skip=1; next }
    /^# END REMNAWAVE PANEL$/ { skip=0; next }
    skip != 1 { print }
  ' "$caddyfile" > "$tmp_file"

  {
    printf "\n# BEGIN REMNAWAVE PANEL\n"
    printf "%s {\n" "$panel_domain"
    printf "\tencode zstd gzip\n"
    printf "\tlog {\n"
    printf "\t\toutput file /var/log/caddy/remnawave-panel.access.log {\n"
    printf "\t\t\troll_size 100MiB\n"
    printf "\t\t\troll_keep 10\n"
    printf "\t\t\troll_keep_for 720h\n"
    printf "\t\t}\n"
    printf "\t\tformat json\n"
    printf "\t}\n"
    printf "\theader {\n"
    printf "\t\tStrict-Transport-Security \"max-age=31536000; includeSubDomains\"\n"
    printf "\t\tX-Content-Type-Options \"nosniff\"\n"
    printf "\t\tX-Frame-Options \"SAMEORIGIN\"\n"
    printf "\t\tReferrer-Policy \"strict-origin-when-cross-origin\"\n"
    printf "\t}\n"
    printf "\treverse_proxy 127.0.0.1:3000\n"
    printf "}\n"
    printf "# END REMNAWAVE PANEL\n"
  } >> "$tmp_file"

  install -o root -g caddy -m 640 "$tmp_file" "$caddyfile"

  rm -f "$tmp_file"

  run_cmd_stream "Validate Caddy configuration" caddy validate --config "$caddyfile"

  run_cmd "Reload Caddy" systemctl reload caddy

  ok "Caddy configured for ${panel_domain}. Certificate issuance will be handled automatically by Caddy."
}

install_nginx() {
  if command_exists nginx; then
    ok "NGINX is already installed."

    run_cmd_stream "Install Certbot NGINX plugin" apt-get install -y certbot python3-certbot-nginx

    run_cmd "Ensure NGINX service is enabled" systemctl enable --now nginx || true
  else
    section "NGINX"

    run_cmd_stream "Install NGINX apt repository key" bash -c 'curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --yes --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg'
    
    echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/ubuntu $(lsb_release -cs) nginx" > /etc/apt/sources.list.d/nginx.list
    
    printf '%s\n' \
      'Package: *' \
      'Pin: origin nginx.org' \
      'Pin: release o=nginx' \
      'Pin-Priority: 900' > /etc/apt/preferences.d/99nginx
    
    run_cmd_stream "Update apt package index for NGINX" apt-get update

    run_cmd_stream "Install NGINX and Certbot" apt-get install -y nginx certbot python3-certbot-nginx

    run_cmd "Enable and start NGINX" systemctl enable --now nginx
  fi
}

configure_nginx_panel() {
  local panel_domain="$1"
  local email="$2"

  local conf="/etc/nginx/conf.d/remnawave-panel.conf"

  local certbot_args=()

  install_nginx

  if [ -f "$conf" ]; then
    cp "$conf" "${conf}.bak.$(date +%Y%m%d%H%M%S)"
  fi

  cat > "$conf" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${panel_domain};

    access_log /var/log/nginx/remnawave-panel.access.log;
    error_log /var/log/nginx/remnawave-panel.error.log warn;

    client_max_body_size 64m;

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_connect_timeout 10s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }
}
EOF

  run_cmd_stream "Validate NGINX configuration" nginx -t

  run_cmd "Reload NGINX" systemctl reload nginx

  if [ -n "$email" ]; then
    certbot_args+=(--email "$email")
  else
    certbot_args+=(--register-unsafely-without-email)
  fi

  run_cmd_stream "Issue TLS certificate with Certbot" certbot --nginx -d "$panel_domain" "${certbot_args[@]}" --agree-tos --non-interactive --redirect

  setup_certbot_auto_renew "nginx" || warn "Certbot auto-renew setup reported an error."

  run_cmd_stream "Validate NGINX configuration after Certbot" nginx -t

  run_cmd "Reload NGINX after Certbot" systemctl reload nginx

  ok "NGINX and TLS configured for ${panel_domain}."
}

configure_caddy_subscription_page() {
  local subscription_domain="$1"
  local email="$2"

  local caddyfile="/etc/caddy/Caddyfile"

  local tmp_file

  install_caddy

  mkdir -p /etc/caddy /var/log/caddy
  chown -R caddy:caddy /var/log/caddy || true
  touch /var/log/caddy/remnawave-subscription-page.access.log
  chown caddy:caddy /var/log/caddy/remnawave-subscription-page.access.log || true
  chmod 640 /var/log/caddy/remnawave-subscription-page.access.log || true

  [ -f "$caddyfile" ] || touch "$caddyfile"
  cp "$caddyfile" "${caddyfile}.bak.$(date +%Y%m%d%H%M%S)"

  ensure_caddy_global_email "$caddyfile" "$email"

  tmp_file="$(mktemp)"

  awk '
    /^# BEGIN REMNAWAVE SUBSCRIPTION PAGE$/ { skip=1; next }
    /^# END REMNAWAVE SUBSCRIPTION PAGE$/ { skip=0; next }
    skip != 1 { print }
  ' "$caddyfile" > "$tmp_file"

  {
    printf "\n# BEGIN REMNAWAVE SUBSCRIPTION PAGE\n"
    printf "%s {\n" "$subscription_domain"
    printf "\tencode zstd gzip\n"
    printf "\tlog {\n"
    printf "\t\toutput file /var/log/caddy/remnawave-subscription-page.access.log {\n"
    printf "\t\t\troll_size 100MiB\n"
    printf "\t\t\troll_keep 10\n"
    printf "\t\t\troll_keep_for 720h\n"
    printf "\t\t}\n"
    printf "\t\tformat json\n"
    printf "\t}\n"
    printf "\theader {\n"
    printf "\t\tStrict-Transport-Security \"max-age=31536000; includeSubDomains\"\n"
    printf "\t\tX-Content-Type-Options \"nosniff\"\n"
    printf "\t\tReferrer-Policy \"strict-origin-when-cross-origin\"\n"
    printf "\t}\n"
    printf "\t@subscription_root path /\n"
    printf "\thandle @subscription_root {\n"
    printf "\t\trespond \"OK\" 200\n"
    printf "\t}\n"
    printf "\thandle {\n"
    printf "\t\treverse_proxy 127.0.0.1:3010\n"
    printf "\t}\n"
    printf "}\n"
    printf "# END REMNAWAVE SUBSCRIPTION PAGE\n"
  } >> "$tmp_file"

  install -o root -g caddy -m 640 "$tmp_file" "$caddyfile"
  rm -f "$tmp_file"

  run_cmd_stream "Validate Caddy configuration for subscription page" caddy validate --config "$caddyfile"
  run_cmd "Reload Caddy after subscription page configuration" systemctl reload caddy

  ok "Caddy configured for subscription page: ${subscription_domain}."
}

configure_nginx_subscription_page() {
  local subscription_domain="$1"
  local email="$2"

  local conf="/etc/nginx/conf.d/remnawave-subscription-page.conf"

  local certbot_args=()

  install_nginx

  if [ -f "$conf" ]; then
    cp "$conf" "${conf}.bak.$(date +%Y%m%d%H%M%S)"
  fi

  cat > "$conf" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${subscription_domain};

    access_log /var/log/nginx/remnawave-subscription-page.access.log;
    error_log /var/log/nginx/remnawave-subscription-page.error.log warn;

    location = / {
        add_header Content-Type text/plain;
        return 200 "OK\n";
    }

    location / {
        proxy_pass http://127.0.0.1:3010;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_connect_timeout 10s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }
}
EOF

  run_cmd_stream "Validate NGINX subscription page configuration" nginx -t
  run_cmd "Reload NGINX after subscription page configuration" systemctl reload nginx

  if [ -n "$email" ]; then
    certbot_args+=(--email "$email")
  else
    certbot_args+=(--register-unsafely-without-email)
  fi

  run_cmd_stream "Issue TLS certificate for subscription page" certbot --nginx -d "$subscription_domain" "${certbot_args[@]}" --agree-tos --non-interactive --redirect

  setup_certbot_auto_renew "nginx" || warn "Certbot auto-renew setup reported an error."

  run_cmd_stream "Validate NGINX subscription page configuration after Certbot" nginx -t
  run_cmd "Reload NGINX after subscription page Certbot" systemctl reload nginx

  ok "NGINX and TLS configured for subscription page: ${subscription_domain}."
}

configure_panel_reverse_proxy() {
  local panel_domain="$1"
  local webserver="$2"
  local email="$3"

  open_web_ports_if_needed

  case "$webserver" in
    caddy) configure_caddy_panel "$panel_domain" "$email" ;;
    nginx) configure_nginx_panel "$panel_domain" "$email" ;;
    none) warn "Reverse proxy skipped. Panel is available locally at 127.0.0.1:3000 only." ;;
    *) die "Unknown webserver: $webserver" ;;
  esac
}

configure_subscription_reverse_proxy() {
  local subscription_domain="$1"
  local webserver="$2"
  local email="$3"

  open_web_ports_if_needed

  case "$webserver" in
    caddy) configure_caddy_subscription_page "$subscription_domain" "$email" ;;
    nginx) configure_nginx_subscription_page "$subscription_domain" "$email" ;;
    none) warn "Reverse proxy skipped. Subscription page is available locally at 127.0.0.1:3010 only." ;;
    *) die "Unknown webserver: $webserver" ;;
  esac
}

http_status_code() {
  local url="$1"
  local timeout="${2:-$HTTP_CHECK_TIMEOUT}"
  local status

  shift
  if [ "$#" -gt 0 ]; then shift; fi
  status="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout "$timeout" --max-time "$timeout" "$@" "$url" 2>/dev/null)" || status="000"

  case "$status" in
    [0-9][0-9][0-9]) printf '%s' "$status" ;;
    *) printf '000' ;;
  esac
}

is_http_ready_status() {
  case "$1" in
    200) return 0 ;;
    *) return 1 ;;
  esac
}

is_http_success_status() {
  case "$1" in
    2??|3??) return 0 ;;
    *) return 1 ;;
  esac
}

wait_for_http_status() {
  local label="$1"
  local url="$2"
  local mode="$3"
  local attempts="${4:-20}"
  local delay="${5:-3}"
  local status_var="$6"
  local timeout_seconds=$((attempts * delay))

  local started_at
  local elapsed
  local spinner_index=0
  local spinner='-\|/'
  local frame
  local response_status="000"
  shift 6

  started_at="$(date +%s)"

  while true; do
    response_status="$(http_status_code "$url" "$HTTP_CHECK_TIMEOUT" "$@")"

    case "$mode" in
      ready)
        if is_http_ready_status "$response_status"; then
          clear_wait_line
          printf -v "$status_var" '%s' "$response_status"

          return 0
        fi
        ;;
      success)
        if is_http_success_status "$response_status"; then
          clear_wait_line
          printf -v "$status_var" '%s' "$response_status"

          return 0
        fi
        ;;
      *) die "Unknown HTTP wait mode: ${mode}" ;;
    esac

    elapsed=$(($(date +%s) - started_at))

    if [ "$elapsed" -ge "$timeout_seconds" ]; then
      break
    fi

    frame="${spinner:$((spinner_index % 4)):1}"
    spinner_index=$((spinner_index + 1))

    printf "\r%s %s (%ss elapsed, last HTTP %s)" "$frame" "$label" "$elapsed" "$response_status"

    sleep "$WAIT_REFRESH_INTERVAL"
  done

  clear_wait_line
  printf -v "$status_var" '%s' "$response_status"

  return 1
}

check_panel_url() {
  local panel_domain="$1"
  local webserver="$2"

  local attempts="${3:-20}"
  local delay="${4:-3}"

  local status

  if [ "$webserver" = "none" ]; then
    if wait_for_http_status "Checking local Panel API" "http://127.0.0.1:3000/api/auth/status" ready "$attempts" "$delay" status -H 'X-Forwarded-Proto: https' -H 'X-Forwarded-For: 127.0.0.1'; then
      ok "Local Panel check passed: http://127.0.0.1:3000 (${status})"
      return 0
    else
      warn "Local Panel check failed: http://127.0.0.1:3000 (last HTTP ${status})."
      return 1
    fi
  fi

  if wait_for_http_status "Checking Panel HTTPS API https://${panel_domain}" "https://${panel_domain}/api/auth/status" ready "$attempts" "$delay" status; then
    ok "HTTPS check passed: https://${panel_domain} (${status})"

    return 0
  fi

  warn "HTTPS check failed for https://${panel_domain} (last HTTP ${status}). Check DNS, firewall, reverse proxy, and logs."
  return 1
}

check_subscription_page_url() {
  local subscription_domain="$1"
  local webserver="$2"

  local attempts="${3:-20}"
  local delay="${4:-3}"

  local status
  local attempt
  local healthy=false

  # Upstream restricts health to container loopback without forwarding headers.
  # The public root is generated by the proxy and cannot prove service health.
  for ((attempt = 0; attempt < attempts; attempt++)); do
    if docker exec remnawave-subscription-page curl -fsS -o /dev/null \
      --connect-timeout "$HTTP_CHECK_TIMEOUT" --max-time "$HTTP_CHECK_TIMEOUT" \
      http://127.0.0.1:3010/internal/health >/dev/null 2>&1; then
      healthy=true
      break
    fi
    if ((attempt + 1 < attempts)); then sleep "$delay"; fi
  done

  if [ "$healthy" != true ]; then
    warn "Subscription page service health check failed. Check its container logs."
    return 1
  fi
  ok "Subscription page internal service health check passed."

  if [ "$webserver" = "none" ]; then
    return 0
  fi

  if wait_for_http_status "Checking subscription page HTTPS https://${subscription_domain}" "https://${subscription_domain}" success "$attempts" "$delay" status; then
    ok "Public HTTPS certificate and proxy root check passed: https://${subscription_domain} (${status}). Test a real user subscription URL to verify delivery."

    return 0
  fi

  warn "HTTPS check failed for https://${subscription_domain} (last HTTP ${status}). Check DNS, firewall, reverse proxy, and logs."
  return 1
}

get_docker_network_subnet() {
  local network="$1"

  docker network inspect "$network" -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null || true
}

get_docker_network_gateway() {
  local network="$1"

  local gateway
  local subnet

  gateway="$(docker network inspect "$network" -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null || true)"

  if [ -n "$gateway" ] && [ "$gateway" != "<no value>" ]; then
    printf "%s" "$gateway"

    return 0
  fi

  subnet="$(get_docker_network_subnet "$network")"

  if [ -n "$subnet" ] && command_exists python3; then
    python3 - "$subnet" <<'PY' 2>/dev/null || true
import ipaddress
import sys

network = ipaddress.ip_network(sys.argv[1], strict=False)
print(next(network.hosts()))
PY
  fi
}

remove_panel_reverse_proxy() {
  local webserver="${WEBSERVER:-}"
  local panel_domain="${PANEL_DOMAIN:-}"
  local subscription_domain="${SUBSCRIPTION_DOMAIN:-}"

  local tmp_file

  if [ -z "$webserver" ]; then
    warn "Saved webserver type was not found. Reverse proxy cleanup skipped."

    return 0
  fi

  case "$webserver" in
    caddy)
      if [ -f /etc/caddy/Caddyfile ]; then
        cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.bak.$(date +%Y%m%d%H%M%S)"

        tmp_file="$(mktemp)"

        awk '
          /^# BEGIN REMNAWAVE PANEL$/ { skip=1; next }
          /^# END REMNAWAVE PANEL$/ { skip=0; next }
          /^# BEGIN REMNAWAVE SUBSCRIPTION PAGE$/ { skip=1; next }
          /^# END REMNAWAVE SUBSCRIPTION PAGE$/ { skip=0; next }
          skip != 1 { print }
        ' /etc/caddy/Caddyfile > "$tmp_file"

        install -o root -g caddy -m 640 "$tmp_file" /etc/caddy/Caddyfile
        rm -f "$tmp_file"

        run_cmd_stream "Validate Caddy configuration after cleanup" caddy validate --config /etc/caddy/Caddyfile && run_cmd "Reload Caddy after cleanup" systemctl reload caddy || true
      fi
      ;;
    nginx)
      rm -f /etc/nginx/conf.d/remnawave-panel.conf
      rm -f /etc/nginx/conf.d/remnawave-subscription-page.conf

      run_cmd_stream "Validate NGINX configuration after cleanup" nginx -t && run_cmd "Reload NGINX after cleanup" systemctl reload nginx || true

      if [ -n "$panel_domain" ] && command_exists certbot && confirm "Delete Let's Encrypt certificate for ${panel_domain}?"; then
        run_cmd_stream "Delete Let's Encrypt certificate for ${panel_domain}" certbot delete --cert-name "$panel_domain" --non-interactive || true
      fi

      if [ -n "$subscription_domain" ] && command_exists certbot && confirm "Delete Let's Encrypt certificate for ${subscription_domain}?"; then
        run_cmd_stream "Delete Let's Encrypt certificate for ${subscription_domain}" certbot delete --cert-name "$subscription_domain" --non-interactive || true
      fi
      ;;
    none) ;;
  esac
}

# REVERSE_PROXY END

# CERTIFICATES BEGIN

install_certbot_dns_plugin() {
  local provider="$1"

  section "Certbot DNS plugin"
  run_cmd_stream "Update apt package index for Certbot" apt-get update

  run_cmd_stream "Install Certbot DNS dependencies" apt-get install -y certbot python3-pip python3-certbot-dns-cloudflare

  if [ "$provider" = "gcore" ]; then
    if python3 -m pip install --help 2>&1 | grep -q "break-system-packages"; then
      run_cmd_stream "Install certbot-dns-gcore" python3 -m pip install --break-system-packages certbot-dns-gcore
    else
      run_cmd_stream "Install certbot-dns-gcore" python3 -m pip install certbot-dns-gcore
    fi
  fi
}

issue_cloudflare_wildcard_cert() {
  local base_domain
  local email
  local token

  local cred_file="/root/.secrets/certbot/cloudflare.ini"

  ask_validated "Base domain, for example example.com" base_domain validate_domain "Enter a domain such as example.com, without a URL or path."

  ask_required "Email Let's Encrypt" email

  ask_secret_required "Cloudflare API token" token

  install_certbot_dns_plugin "cloudflare"

  mkdir -p /root/.secrets/certbot
  
  cat > "$cred_file" <<EOF
dns_cloudflare_api_token = ${token}
EOF
  chmod 600 "$cred_file"

  run_cmd_stream "Issue Cloudflare DNS-01 wildcard certificate" certbot certonly \
    --dns-cloudflare \
    --dns-cloudflare-credentials "$cred_file" \
    --dns-cloudflare-propagation-seconds 60 \
    -d "$base_domain" \
    -d "*.${base_domain}" \
    --email "$email" \
    --agree-tos \
    --non-interactive \
    --key-type ecdsa \
    --elliptic-curve secp384r1

  setup_certbot_auto_renew "nginx" || warn "Certbot auto-renew setup reported an error."
}

issue_gcore_wildcard_cert() {
  local base_domain
  local email
  local token

  local cred_file="/root/.secrets/certbot/gcore.ini"

  ask_validated "Base domain, for example example.com" base_domain validate_domain "Enter a domain such as example.com, without a URL or path."

  ask_required "Email Let's Encrypt" email

  ask_secret_required "Gcore API token" token

  install_certbot_dns_plugin "gcore"

  mkdir -p /root/.secrets/certbot

  cat > "$cred_file" <<EOF
dns_gcore_apitoken = ${token}
EOF
  chmod 600 "$cred_file"

  run_cmd_stream "Issue Gcore DNS-01 wildcard certificate" certbot certonly \
    --authenticator dns-gcore \
    --dns-gcore-credentials "$cred_file" \
    --dns-gcore-propagation-seconds 80 \
    -d "$base_domain" \
    -d "*.${base_domain}" \
    --email "$email" \
    --agree-tos \
    --non-interactive \
    --key-type ecdsa \
    --elliptic-curve secp384r1

  setup_certbot_auto_renew "nginx" || warn "Certbot auto-renew setup reported an error."
}

setup_certbot_auto_renew() {
  local reload_target="${1:-nginx}"

  local hook
  local hook_script="/etc/letsencrypt/renewal-hooks/deploy/99-remnawave-reload.sh"
  local hook_dir

  case "$reload_target" in
    nginx) hook="systemctl reload nginx" ;;
    caddy) hook="systemctl reload caddy" ;;
    *) hook="true" ;;
  esac

  run_cmd "Enable Certbot timer" systemctl enable --now certbot.timer || true

  hook_dir="$(dirname "$hook_script")"

  if ! run_cmd "Create Certbot deploy hook directory" install -d -m 755 "$hook_dir"; then
    warn "Failed to create Certbot deploy hook directory. Continuing without installer-managed deploy hook."

    return 0
  fi

  if ! bash -c "cat > '$hook_script' <<'EOF'
#!/usr/bin/env bash
set -e
${hook}
EOF
  "; then
    warn "Failed to write Certbot deploy hook to ${hook_script}. Continuing without installer-managed deploy hook."

    return 0
  fi

  if ! run_cmd "Set Certbot deploy hook permissions" chmod 755 "$hook_script"; then
    warn "Failed to set permissions on ${hook_script}. Continuing without installer-managed deploy hook."

    return 0
  fi

  if command_exists crontab; then
    if ! bash -c "(crontab -u root -l 2>/dev/null | grep -vF '$CERTBOT_RENEW_CRON'; true) | crontab -u root -"; then
      warn "Failed to clean installer-managed Certbot cron entry. Continuing with certbot.timer + deploy hook."
    fi
  else
    warn "crontab command was not found. Using certbot.timer + deploy hook only."
  fi

  ok "Certbot auto-renew configured with deploy hook: ${hook}"

  return 0
}

remove_certbot_renew_cron() {
  local hook_script="/etc/letsencrypt/renewal-hooks/deploy/99-remnawave-reload.sh"

  if command_exists crontab; then
    (crontab -u root -l 2>/dev/null | grep -vF "$CERTBOT_RENEW_CRON"; true) | crontab -u root -
  fi

  rm -f "$hook_script"

  ok "Installer-managed certbot renew automation removed."
}

list_certificates() {
  run_cmd_stream "List Certbot certificates" certbot certificates || true
}

renew_certificates_dry_run() {
  run_cmd_stream "Run Certbot renew dry-run" certbot renew --dry-run
}

# CERTIFICATES END

# COMPOSE BEGIN

clear_wait_line() {
  printf "\r\033[K"
}

wait_for_compose_service_ready() {
  local service="$1"

  local attempts="${2:-60}"
  local delay="${3:-3}"
  local timeout_seconds=$((attempts * delay))

  local container_id
  local status
  local health
  local started_at
  local spinner_index=0
  local elapsed
  local spinner='-\|/'
  local frame

  started_at="$(date +%s)"

  while true; do
    status="unknown"
    health="none"

    container_id="$(docker compose ps -q "$service" 2>/dev/null || true)"

    if [ -n "$container_id" ]; then
      status="$(docker inspect -f '{{.State.Status}}' "$container_id" 2>/dev/null || true)"

      health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$container_id" 2>/dev/null || true)"

      if [ "$health" = "healthy" ] || { [ -z "$health" ] && [ "$status" = "running" ]; }; then
        clear_wait_line
        ok "Service ${service} is ready."

        return 0
      fi
    fi

    elapsed=$(($(date +%s) - started_at))

    if [ "$elapsed" -ge "$timeout_seconds" ]; then
      break
    fi

    frame="${spinner:$((spinner_index % 4)):1}"
    spinner_index=$((spinner_index + 1))

    printf "\r%s Waiting for %s to become ready (%ss elapsed, status: %s, health: %s)" \
      "$frame" \
      "$service" \
      "$elapsed" \
      "${status:-unknown}" \
      "${health:-none}"

    sleep "$WAIT_REFRESH_INTERVAL"
  done

  clear_wait_line

  return 1
}

compose_action() {
  local dir="$1"
  local action="$2"

  local compose_files=(-f docker-compose.yml)

  [ -f "${dir}/docker-compose.yml" ] || die "Missing ${dir}/docker-compose.yml."
  cd "$dir"

  if [ -f docker-compose.subscription.yml ]; then
    compose_files+=(-f docker-compose.subscription.yml)
  fi

  case "$action" in
    start)
      if [ "$dir" = "$PANEL_DIR" ]; then
        start_panel_stack
      else
        run_cmd_stream "Start compose stack in ${dir}" docker compose "${compose_files[@]}" up -d
      fi
      ;;
    stop) run_cmd_stream "Stop compose stack in ${dir}" docker compose "${compose_files[@]}" down ;;
    restart)
      if [ "$dir" = "$PANEL_DIR" ]; then
        validate_panel_v3 || return 1
      fi
      run_cmd_stream "Stop compose stack in ${dir}" docker compose "${compose_files[@]}" down
      if [ "$dir" = "$PANEL_DIR" ]; then
        start_panel_stack
      else
        run_cmd_stream "Start compose stack in ${dir}" docker compose "${compose_files[@]}" up -d
      fi
      ;;
    update)
      run_cmd_stream "Pull compose images in ${dir}" docker compose "${compose_files[@]}" pull || return 1
      if [ "$dir" = "$PANEL_DIR" ]; then
        start_panel_stack
      else
        run_cmd_stream "Start updated compose stack in ${dir}" docker compose "${compose_files[@]}" up -d
      fi
      ;;
    logs) run_cmd_stream "Follow compose logs in ${dir}" docker compose "${compose_files[@]}" logs -f -t ;;
    status) run_cmd_stream "Show compose status in ${dir}" docker compose "${compose_files[@]}" ps ;;
    *) die "Unknown compose action: $action" ;;
  esac
}

# COMPOSE END

# PANEL BEGIN

configure_panel_env() {
  local file="$1"
  local panel_domain="$2"
  local subscription_domain="$3"
  local pg_pass app_secret metrics_pass webhook_secret

  pg_pass="$(random_hex 24)" || return 1
  app_secret="$(random_hex 64)" || return 1
  metrics_pass="$(random_hex 64)" || return 1
  webhook_secret="$(random_hex 32)" || return 1
  set_env_value "$file" "APP_SECRET" "$app_secret" || return 1
  set_env_value "$file" "METRICS_PASS" "$metrics_pass" || return 1
  set_env_value "$file" "WEBHOOK_SECRET_HEADER" "$webhook_secret" || return 1
  set_env_value "$file" "POSTGRES_USER" "postgres" || return 1
  set_env_value "$file" "POSTGRES_PASSWORD" "$pg_pass" || return 1
  set_env_value "$file" "POSTGRES_DB" "postgres" || return 1
  set_env_value "$file" "DATABASE_URL" "\"postgresql://postgres:${pg_pass}@remnawave-db:5432/postgres\"" || return 1
  set_env_value "$file" "FRONT_END_DOMAIN" "$panel_domain" || return 1
  set_env_value "$file" "SUB_PUBLIC_DOMAIN" "$subscription_domain" || return 1
  set_env_value "$file" "PANEL_DOMAIN" "$panel_domain"
}

validate_panel_v3() (
  local config
  local compose_files=(-f docker-compose.yml)

  cd "$PANEL_DIR" || return 1
  [ ! -f docker-compose.subscription.yml ] || compose_files+=(-f docker-compose.subscription.yml)
  config="$(docker compose "${compose_files[@]}" config --format json)" || return 1
  if ! printf '%s' "$config" | jq -e '
    .services.remnawave as $panel |
    ($panel.image | test("^(ghcr.io/)?remnawave/backend:3(\\.[0-9]+){0,2}(@sha256:[a-f0-9]+)?$")) and
    (($panel.environment.APP_SECRET // "") | length > 0) and
    ($panel.environment.APP_SECRET != "change_me")
  ' >/dev/null; then
    warn "This installer requires Remnawave v3 (backend:3 or a 3.x release) and a configured APP_SECRET."
    return 1
  fi
)

wait_for_panel_database() {
  local attempts="${1:-60}"
  local delay="${2:-3}"
  local timeout_seconds=$((attempts * delay))

  local started_at
  local elapsed
  local spinner_index=0
  local spinner='-\|/'
  local frame

  started_at="$(date +%s)"

  while true; do
    if docker compose exec -T remnawave-db sh -c 'pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB"' >/dev/null 2>&1; then
      clear_wait_line

      ok "Postgres is ready."

      return 0
    fi

    elapsed=$(($(date +%s) - started_at))

    if [ "$elapsed" -ge "$timeout_seconds" ]; then
      break
    fi

    frame="${spinner:$((spinner_index % 4)):1}"
    spinner_index=$((spinner_index + 1))

    printf "\r%s Waiting for Postgres to accept connections (%ss elapsed)" "$frame" "$elapsed"

    sleep "$WAIT_REFRESH_INTERVAL"
  done

  clear_wait_line

  return 1
}

start_panel_stack() {
  local recreate="${1:-}"
  local compose_files=(-f docker-compose.yml)
  local recreate_args=()

  validate_panel_v3 || return 1
  cd "$PANEL_DIR" || return 1
  [ ! -f docker-compose.subscription.yml ] || compose_files+=(-f docker-compose.subscription.yml)
  [ "$recreate" != "force" ] || recreate_args+=(--force-recreate)

  section "Start Panel stack"
  step "Starting database and Redis."
  run_cmd_stream "Start Remnawave database and Redis" docker compose "${compose_files[@]}" up -d remnawave-db remnawave-redis || return 1
  wait_for_compose_service_ready remnawave-db 10 10 || return 1
  wait_for_panel_database 10 10 || return 1
  wait_for_compose_service_ready remnawave-redis 10 10 || return 1

  step "Starting Remnawave backend."
  run_cmd_stream "Start Remnawave backend" docker compose "${compose_files[@]}" up -d --no-deps "${recreate_args[@]}" remnawave || return 1
  if ! wait_for_compose_service_ready remnawave 120 5; then
    warn "Remnawave backend did not become healthy. Check its logs before starting dependent services."
    return 1
  fi

  run_cmd_stream "Start remaining Panel services" docker compose "${compose_files[@]}" up -d || return 1
  if [ -f docker-compose.subscription.yml ]; then
    if [ "$recreate" = "force" ]; then
      run_cmd_stream "Recreate subscription page" docker compose "${compose_files[@]}" up -d --no-deps --force-recreate remnawave-subscription-page || return 1
    fi
    check_subscription_page_url "" none || return 1
  fi

  return 0
}

create_panel_admin() {
  local panel_base="${1:-}"
  local mode username="" password response access_token response_file http_code register_allowed
  PANEL_ADMIN_USERNAME=""
  PANEL_ADMIN_PASSWORD=""

  if [ -z "$panel_base" ]; then
    panel_base="$(default_panel_api_base)"
  fi

  if ! response=$(curl -fsS -H "X-Forwarded-Proto: https" -H "X-Forwarded-For: 127.0.0.1" "${panel_base%/}/api/auth/status"); then
    warn "Panel API at ${panel_base} did not respond. Retry admin creation from the Panel menu."
    return 1
  fi
  register_allowed=$(printf '%s\n' "$response" | jq -r '.response.isRegisterAllowed | if type == "boolean" then tostring else empty end' 2>/dev/null) || register_allowed=""
  case "$register_allowed" in
    false) ok "Panel admin is already registered; registration is disabled."; return 0 ;;
    true) ;;
    *) warn "Panel returned an invalid authentication status. Retry admin creation later."; return 1 ;;
  esac

  while true; do
    menu_title "Panel admin creation"
    menu_item 1 "Enter username/password manually"
    menu_item 2 "Generate automatically"
    menu_item 0 "Skip"
    blank
    ask_choice "Selection" mode 0 2 "1" || return 130

    case "$mode" in
      1)
        ask_required "Admin username" username "$username" || return 130
        info "Admin password requires at least 24 characters, including uppercase and lowercase letters and numbers."
        while true; do
          ask_secret_required "Admin password" password || return 130
          if validate_admin_password "$password"; then break; fi
          warn "Password must be at least 24 characters and include uppercase and lowercase letters and numbers. Please try again."
        done
        ;;
      2)
        username="$(random_username)"
        password="$(random_password)"
        ;;
      0)
        warn "Panel admin creation skipped. You can finish it later from the Panel menu."
        return 0
        ;;
    esac

    response_file="$(mktemp)" || return 1
    http_code=$(curl -sS -o "$response_file" -w "%{http_code}" -X POST "${panel_base%/}/api/auth/register" \
      -H "Content-Type: application/json" \
      -H "X-Forwarded-Proto: https" \
      -H "X-Forwarded-For: 127.0.0.1" \
      -H "X-Remnawave-Client-Type: browser" \
      --data "$(jq -n --arg username "$username" --arg password "$password" '{username:$username,password:$password}')") || http_code="000"
    response="$(cat "$response_file")"
    rm -f "$response_file"

    if [[ ! "$http_code" =~ ^2[0-9][0-9]$ ]]; then
      warn "Panel admin registration failed (HTTP ${http_code}). Check your input and retry, or skip and finish later."
      continue
    fi
    access_token=$(printf '%s\n' "$response" | jq -r '.response.accessToken // empty' 2>/dev/null) || access_token=""
    if [ -z "$access_token" ]; then
      warn "Panel registration did not return an access token. Check the Panel before retrying admin creation."
      return 1
    fi

    PANEL_ADMIN_USERNAME="$username"
    PANEL_ADMIN_PASSWORD="$password"
    remember_panel_auth "$panel_base" "$access_token" "$username" "$password"
    ok "Panel admin created."
    return 0
  done
}

print_panel_summary() {
  local panel_domain="$1"
  local webserver="$2"

  local subscription_domain="${3:-${SUBSCRIPTION_DOMAIN:-}}"

  section "Completed: Remnawave Panel"

  summary_item "URL" "https://${panel_domain}"

  if [ -n "$subscription_domain" ]; then
    summary_item "Subscription URL" "https://${subscription_domain}"
  fi

  summary_item "Directory" "${PANEL_DIR}"
  summary_item "ENV" "${PANEL_DIR}/.env"
  summary_item "Compose" "${PANEL_DIR}/docker-compose.yml"
  summary_item "Reverse proxy" "${webserver}"

  if [ -n "$PANEL_ADMIN_USERNAME" ] && [ -n "$PANEL_ADMIN_PASSWORD" ]; then
    summary_item "Admin username" "${PANEL_ADMIN_USERNAME}"
    summary_item "Admin password" "${PANEL_ADMIN_PASSWORD}"
  fi

  summary_item "Panel logs" "sudo bash install_remnawave.sh -> Panel -> Logs"
  summary_item "Status" "cd ${PANEL_DIR} && docker compose ps"

  blank
}

prepare_new_panel_files() (
  local panel_domain="$1" subscription_domain="$2"
  local stage published=0 file
  umask 077
  mkdir -p "$PANEL_DIR" || return 1
  for file in .env docker-compose.yml; do
    if [ -e "$PANEL_DIR/$file" ] || [ -L "$PANEL_DIR/$file" ]; then
      warn "Existing Panel configuration will not be overwritten: ${PANEL_DIR}/${file}"
      return 1
    fi
  done
  stage="$(mktemp -d "$PANEL_DIR/.install.XXXXXX")" || return 1
  cleanup_panel_files() {
    local status="$?" file
    if [ "$published" = 0 ]; then
      for file in .env docker-compose.yml; do
        if [ "$PANEL_DIR/$file" -ef "$stage/$file" ]; then
          rm -f -- "$PANEL_DIR/$file" || status=1
        fi
      done
    fi
    rm -rf -- "$stage" || status=1
    exit "$status"
  }
  trap cleanup_panel_files EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  run_cmd "Download Remnawave docker-compose.yml" curl -fsSL "$PANEL_COMPOSE_URL" -o "$stage/docker-compose.yml" || return 1
  run_cmd "Download Remnawave .env.sample" curl -fsSL "$PANEL_ENV_URL" -o "$stage/.env" || return 1
  chmod 600 "$stage/.env" || return 1
  configure_panel_env "$stage/.env" "$panel_domain" "$subscription_domain" || return 1
  PANEL_DIR="$stage" validate_panel_v3 || return 1
  # Hard links publish without replacing files created by another installation.
  ln -T -- "$stage/.env" "$PANEL_DIR/.env" || return 1
  ln -T -- "$stage/docker-compose.yml" "$PANEL_DIR/docker-compose.yml" || return 1
  published=1
)

install_panel() {
  local panel_domain
  local subscription_domain
  local subscription_domain_default
  local letsencrypt_email
  local webserver_choice
  local webserver

  section "Install Remnawave Panel"

  if [ -e "$PANEL_DIR/.env" ] || [ -L "$PANEL_DIR/.env" ] ||
    [ -e "$PANEL_DIR/docker-compose.yml" ] || [ -L "$PANEL_DIR/docker-compose.yml" ]; then
    if [ ! -f "$PANEL_DIR/.env" ] || [ ! -f "$PANEL_DIR/docker-compose.yml" ]; then
      warn "Panel configuration is incomplete in ${PANEL_DIR}. Existing files and secrets were preserved."
      note "Restore the missing .env or docker-compose.yml from your backup, then use Panel -> Start."
      note "Newly generated credentials cannot replace the original credentials of an existing database."
      return 1
    fi
    validate_panel_v3 || { warn "Existing Panel configuration needs repair; files and secrets were preserved."; return 1; }
    note "Panel files already exist in ${PANEL_DIR}."
    note "Use Panel -> Start, Create Panel admin, or Configure subscription page to finish setup."
    return 0
  fi

  ask_validated "Panel domain, for example panel.example.com" panel_domain validate_domain "Enter a valid domain without https:// or a path." || return $?

  subscription_domain_default="$(default_subscription_domain "$panel_domain")"

  while true; do
    ask_validated "Subscription page domain, for example sub.example.com" subscription_domain validate_domain "Enter a valid domain without https:// or a path." "$subscription_domain_default" || return $?
    [ "$subscription_domain" = "$panel_domain" ] || break
    warn "Subscription page domain must be different from Panel domain. Try again."
  done

  install_prerequisites

  section "DNS check"

  check_domain_dns "$panel_domain"
  check_domain_dns "$subscription_domain"

  ask "Email for Let's Encrypt/Caddy (can be empty)" letsencrypt_email ""

  menu_title "Select reverse proxy for Panel"
  menu_item 1 "Caddy, automatic certificate"
  menu_item 2 "NGINX + Certbot"
  menu_item 3 "Do not configure reverse proxy"

  blank

  ask_choice "Selection" webserver_choice 1 3 "1" || return $?

  case "$webserver_choice" in
    1) webserver="caddy" ;;
    2) webserver="nginx" ;;
    3) webserver="none" ;;
  esac

  section "Panel files"
  prepare_new_panel_files "$panel_domain" "$subscription_domain" || return $?
  cd "$PANEL_DIR" || return 1

  note "If reverse proxy configuration fails, containers will remain stopped or partially started in ${PANEL_DIR}."

  section "Reverse proxy"

  save_panel_state "$panel_domain" "$webserver" "$letsencrypt_email" "$subscription_domain"
  configure_panel_reverse_proxy "$panel_domain" "$webserver" "$letsencrypt_email"

  section "Panel startup"

  if ! start_panel_stack; then
    run_cmd_stream "Show compose status after Panel startup failure" docker compose ps || true
    run_cmd_stream "Show recent Panel logs after startup failure" docker compose logs --tail=80 remnawave remnawave-db remnawave-redis || true

    die "Remnawave Panel API did not start. Fix the errors above and retry installation/start."
  fi

  section "Panel access check"

  check_panel_url "$panel_domain" "$webserver" || die "Panel access check failed."

  ok "Panel installed in ${PANEL_DIR}."

  if [ "$webserver" = "none" ]; then
    note "Reverse proxy is not configured. Do not expose APP_PORT directly to the public internet."
  else
    ok "Panel should be available at https://${panel_domain}"
  fi

  if confirm "Create Panel admin now?"; then
    section "Panel admin"

    local admin_base="https://${panel_domain}"
    [ "$webserver" != "none" ] || admin_base="http://127.0.0.1:3000"
    if ! create_panel_admin "$admin_base"; then
      note "Panel is installed. Retry admin creation from Panel -> Create Panel admin."
      return 0
    fi
  else
    skip "Panel admin creation skipped by user."
  fi

  print_panel_summary "$panel_domain" "$webserver" "$subscription_domain"

  if confirm "Configure remnawave-subscription-page now?"; then
    section "Subscription page"

    setup_subscription_page_for_panel "$subscription_domain"
  else
    skip "remnawave-subscription-page configuration skipped by user."
  fi
}

create_admin_for_existing_panel() {
  [ -f "$PANEL_DIR/docker-compose.yml" ] || die "Panel is not installed."
  PANEL_ADMIN_USERNAME=""
  PANEL_ADMIN_PASSWORD=""
  create_panel_admin
  if [ -n "$PANEL_ADMIN_USERNAME" ] && [ -n "$PANEL_ADMIN_PASSWORD" ]; then
    printf 'Admin username: %s\nAdmin password: %s\n' "$PANEL_ADMIN_USERNAME" "$PANEL_ADMIN_PASSWORD"
  fi
}

update_panel() {
  section "Update Remnawave Panel"

  validate_panel_v3 || return 1
  backup_panel || return 1

  compose_action "$PANEL_DIR" update
}

reinstall_panel_keep_config() {
  [ -d "$PANEL_DIR" ] || die "Panel is not installed."

  validate_panel_v3 || return 1
  note "Panel reinstall will keep the current compose files, .env and Docker volumes."

  if ! confirm "Continue Panel reinstall?"; then
    warn "Panel reinstall cancelled by user."

    return 0
  fi

  backup_all || return 1
  cd "$PANEL_DIR" || return 1

  section "Reinstall Remnawave Panel"

  local compose_files=(-f docker-compose.yml)
  if [ -f docker-compose.subscription.yml ]; then
    compose_files+=(-f docker-compose.subscription.yml)
  fi
  run_cmd_stream "Pull Panel compose images" docker compose "${compose_files[@]}" pull || return 1
  start_panel_stack force || return 1

  ok "Panel reinstalled with compose files, .env and volumes preserved."
}

remove_panel() {
  load_panel_state

  remove_stack "Panel" "$PANEL_DIR" || return $?
  remove_panel_reverse_proxy

  rm -f "$PANEL_STATE_FILE"
}

remove_panel_with_volumes() {
  load_panel_state

  remove_stack_with_volumes "Panel" "$PANEL_DIR" || return $?
  remove_panel_reverse_proxy

  rm -f "$PANEL_STATE_FILE"
}

# PANEL END

make_panel_api_request() {
  local method="$1"
  local panel_base="$2"
  local token="$3"
  local path="$4"
  local body="${5:-}"

  local url="${panel_base%/}/${path#/}"
  local response_file
  local http_code
  local response

  local headers=(
    -H "Authorization: Bearer ${token}"
    -H "Content-Type: application/json"
    -H "X-Forwarded-For: ${panel_base#http://}"
    -H "X-Forwarded-Proto: https"
    -H "X-Remnawave-Client-Type: browser"
  )

  response_file="$(mktemp)"

  if [ -n "$body" ]; then
    http_code=$(curl -sS -o "$response_file" -w "%{http_code}" -X "$method" "$url" "${headers[@]}" --data "$body") || {
      response="$(cat "$response_file")"

      rm -f "$response_file"

      die "Panel API ${method} ${path} failed: ${response}"
    }
  else
    http_code=$(curl -sS -o "$response_file" -w "%{http_code}" -X "$method" "$url" "${headers[@]}") || {
      response="$(cat "$response_file")"

      rm -f "$response_file"

      die "Panel API ${method} ${path} failed: ${response}"
    }
  fi

  response="$(cat "$response_file")"

  rm -f "$response_file"

  if [ "$http_code" -lt 200 ] || [ "$http_code" -ge 300 ]; then
    die "Panel API ${method} ${path} returned HTTP ${http_code}: ${response}"
  fi

  printf "%s\n" "$response"
}

panel_api_token_is_valid() {
  local panel_base="$1"
  local token="$2"

  local response_file
  local http_code

  [ -n "$panel_base" ] || return 1
  [ -n "$token" ] || return 1

  response_file="$(mktemp)"

  http_code=$(curl -sS -o "$response_file" -w "%{http_code}" -X GET "${panel_base%/}/api/config-profiles" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -H "X-Forwarded-For: ${panel_base#http://}" \
    -H "X-Forwarded-Proto: https" \
    -H "X-Remnawave-Client-Type: browser") || {
      rm -f "$response_file"
      return 1
    }

  rm -f "$response_file"

  [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]
}

login_panel_and_get_token() {
  local panel_base="$1" username="$2" password="$3" token_var="$4"
  local response response_file http_code login_access_token

  printf -v "$token_var" '%s' ''
  response_file="$(mktemp)" || return 1
  http_code=$(curl -sS -o "$response_file" -w "%{http_code}" -X POST "${panel_base%/}/api/auth/login" \
    -H "Content-Type: application/json" \
    -H "X-Forwarded-Proto: https" \
    -H "X-Forwarded-For: 127.0.0.1" \
    -H "X-Remnawave-Client-Type: browser" \
    --data "$(jq -n --arg username "$username" --arg password "$password" '{username:$username,password:$password}')") || http_code="000"
  response="$(cat "$response_file")"
  rm -f "$response_file"

  if [[ ! "$http_code" =~ ^2[0-9][0-9]$ ]]; then
    warn "Panel login failed (HTTP ${http_code}). Check the username/password and Panel availability."
    return 1
  fi
  login_access_token=$(printf '%s\n' "$response" | jq -r '.response.accessToken // empty' 2>/dev/null) || login_access_token=""
  if [ -z "$login_access_token" ]; then
    warn "Panel login did not return an access token."
    return 1
  fi
  printf -v "$token_var" '%s' "$login_access_token"
}

get_panel_api_token() {
  local panel_base="$1" token_var="$2"
  local api_token="" username="" password="" auth_choice answer_status
  local default_username=""

  load_panel_auth_state
  if [ -n "${PANEL_AUTH_TOKEN:-}" ]; then
    answer_status=0
    confirm "Use previously saved Panel API/access token for ${panel_base}?" || answer_status=$?
    [ "$answer_status" -ne 130 ] || return 130
    if [ "$answer_status" -eq 0 ]; then
      if panel_api_token_is_valid "$panel_base" "$PANEL_AUTH_TOKEN"; then
        ok "Using previously saved Panel API/access token."
        printf -v "$token_var" '%s' "$PANEL_AUTH_TOKEN"
        return 0
      fi
      warn "Saved Panel API/access token is no longer valid."
      clear_panel_auth_token
    fi
  fi

  if [ -n "${PANEL_AUTH_USERNAME:-}" ] && [ -n "${PANEL_AUTH_PASSWORD:-}" ]; then
    answer_status=0
    confirm "Use previously saved Panel login/password for ${panel_base}?" || answer_status=$?
    [ "$answer_status" -ne 130 ] || return 130
    if [ "$answer_status" -eq 0 ]; then
      if login_panel_and_get_token "$panel_base" "$PANEL_AUTH_USERNAME" "$PANEL_AUTH_PASSWORD" api_token; then
        if panel_api_token_is_valid "$panel_base" "$api_token"; then
          remember_panel_auth "$panel_base" "$api_token" "$PANEL_AUTH_USERNAME" "$PANEL_AUTH_PASSWORD"
          ok "Using previously saved Panel login/password."
          printf -v "$token_var" '%s' "$api_token"
          return 0
        fi
      fi
      warn "Saved Panel credentials could not be used. Choose another authentication method."
    fi
  fi

  default_username="${PANEL_AUTH_USERNAME:-${PANEL_ADMIN_USERNAME:-}}"
  while true; do
    menu_title "Panel API auth"
    menu_item 1 "Paste existing API/access token"
    menu_item 2 "Panel login/password"
    menu_item 0 "Cancel / back"
    blank
    ask_choice "Selection" auth_choice 0 2 "1" || return 130
    case "$auth_choice" in
      0) return 130 ;;
      1)
        ask_secret_required "Panel API/access token" api_token || return 130
        ;;
      2)
        ask_required "Panel username" username "$default_username" || return 130
        default_username="$username"
        ask_secret_required "Panel password" password || return 130
        if ! login_panel_and_get_token "$panel_base" "$username" "$password" api_token; then continue; fi
        ;;
    esac
    if ! panel_api_token_is_valid "$panel_base" "$api_token"; then
      warn "Token validation failed via /api/config-profiles. Check your credentials and Panel availability, then retry or cancel."
      continue
    fi
    if [ "$auth_choice" = "1" ]; then
      remember_panel_auth "$panel_base" "$api_token"
    else
      remember_panel_auth "$panel_base" "$api_token" "$username" "$password"
    fi
    printf -v "$token_var" '%s' "$api_token"
    return 0
  done
}

create_remnawave_node_api() {
  local panel_base="$1"
  local token="$2"
  local config_uuid="$3"
  local inbound_uuid="$4"
  local address="$5"
  local name="$6"

  local port="${7:-2222}"
  local secret_var="${8:-}"
  local uuid_var="${9:-}"

  local body
  local response
  local response_file
  local http_code
  local node_secret
  local created_node_uuid

  validate_host "$address" || die "Invalid Node address: ${address}"
  validate_port "$port" || die "Invalid Node API port: ${port}"

  body=$(jq -n \
    --arg name "$name" \
    --arg address "$address" \
    --arg configUuid "$config_uuid" \
    --arg inboundUuid "$inbound_uuid" \
    --argjson port "$port" \
    '{
      name: $name,
      address: $address,
      port: $port,
      configProfile: {
        activeConfigProfileUuid: $configUuid,
        activeInbounds: [$inboundUuid]
      },
      isTrafficTrackingActive: false,
      trafficLimitBytes: 0,
      notifyPercent: 0,
      trafficResetDay: 31,
      excludedInbounds: [],
      countryCode: "XX",
      consumptionMultiplier: 1.0
    }')

  response_file="$(mktemp)"

  http_code=$(curl -sS -o "$response_file" -w "%{http_code}" -X POST "${panel_base%/}/api/nodes" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -H "X-Forwarded-For: ${panel_base#http://}" \
    -H "X-Forwarded-Proto: https" \
    -H "X-Remnawave-Client-Type: browser" \
    --data "$body") || {
      rm -f "$response_file"
      die "Failed to call Panel API /api/nodes."
    }

  response="$(cat "$response_file")"

  rm -f "$response_file"

  if [ "$http_code" -lt 200 ] || [ "$http_code" -ge 300 ]; then
    die "Panel API /api/nodes returned HTTP ${http_code}: ${response}"
  fi

  printf "%s\n" "$response" | jq -e '.response.uuid' >/dev/null || die "Failed to create node: $response"

  created_node_uuid=$(printf "%s\n" "$response" | jq -r '.response.uuid // empty')

  node_secret=""

  if [ -n "$secret_var" ]; then
    # Key access is optional: restricted tokens can create nodes without reading keygen.
    response_file="$(mktemp)"

    if http_code=$(curl -sS -o "$response_file" -w "%{http_code}" -X GET "${panel_base%/}/api/keygen" \
      -H "Authorization: Bearer ${token}" \
      -H "Content-Type: application/json" \
      -H "X-Forwarded-For: ${panel_base#http://}" \
      -H "X-Forwarded-Proto: https" \
      -H "X-Remnawave-Client-Type: browser" 2>/dev/null) &&
      [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ] &&
      node_secret=$(jq -er '.response.secretKey | select(type == "string" and length > 0)' "$response_file" 2>/dev/null); then
      :
    else
      node_secret=""
      warn "Node created, but SECRET_KEY could not be obtained from /api/keygen. Enter it manually from Panel."
    fi

    rm -f "$response_file"
  fi

  if [ -n "$uuid_var" ]; then
    printf -v "$uuid_var" '%s' "$created_node_uuid"
  fi

  if [ -n "$secret_var" ]; then
    printf -v "$secret_var" '%s' "$node_secret"
  fi
}

# SUBSCRIPTION_PAGE BEGIN

create_subscription_page_service() {
  local panel_base="$1"
  local token="$2"

  local target_dir="${3:-$PANEL_DIR}"

  local api_token
  local body
  local response

  local override_file="${target_dir}/docker-compose.subscription.yml"
  local env_file="${target_dir}/subscription-page.env"

  [ -f "${target_dir}/docker-compose.yml" ] || die "Missing ${target_dir}/docker-compose.yml."

  step "Creating API token for remnawave-subscription-page."

  body=$(jq -n --arg name "subscription-page" --argjson expiresInDays 3650 '{name:$name,expiresInDays:$expiresInDays}')
  response=$(make_panel_api_request "POST" "$panel_base" "$token" "/api/tokens" "$body")

  api_token=$(printf "%s\n" "$response" | jq -r '.response.token // .response.apiToken // .token // .apiToken // empty')

  [ -n "$api_token" ] || die "Panel did not return subscription-page token: $response"

  cat > "$env_file" <<EOF
REMNAWAVE_PANEL_URL=http://remnawave:3000
APP_PORT=3010
REMNAWAVE_API_TOKEN=${api_token}
EOF
  chmod 600 "$env_file"

  cat > "$override_file" <<EOF
services:
  remnawave-subscription-page:
    image: remnawave/subscription-page:latest
    container_name: remnawave-subscription-page
    hostname: remnawave-subscription-page
    restart: always
    depends_on:
      remnawave:
        condition: service_healthy
    env_file:
      - ./subscription-page.env
    ports:
      - '127.0.0.1:3010:3010'
    networks:
      - remnawave-network
    logging:
      driver: json-file
      options:
        max-size: 30m
        max-file: "5"
EOF

  cd "$target_dir"

  run_cmd_stream "Start remnawave-subscription-page" docker compose -f docker-compose.yml -f docker-compose.subscription.yml up -d remnawave-subscription-page

  ok "Subscription page service configured via ${override_file}."
}

setup_subscription_page_for_panel() {
  local provided_subscription_domain="${1:-}"
  local panel_base
  local default_panel_base
  local panel_domain
  local subscription_domain
  local subscription_domain_default
  local current_sub_public_domain=""
  local should_recreate_panel="0"
  local token
  local webserver
  local letsencrypt_email

  [ -d "$PANEL_DIR" ] && [ -f "$PANEL_DIR/docker-compose.yml" ] || die "Panel was not found in ${PANEL_DIR}."

  load_panel_state

  default_panel_base="$(default_panel_api_base)"

  ask_required "Panel API base URL" panel_base "$default_panel_base"

  panel_domain="${PANEL_DOMAIN:-}"
  if [ -z "$panel_domain" ]; then
    panel_domain="${panel_base#http://}"
    panel_domain="${panel_domain#https://}"
    panel_domain="${panel_domain%%/*}"
  fi

  subscription_domain_default="${SUBSCRIPTION_DOMAIN:-$(default_subscription_domain "$panel_domain")}"

  if [ -n "$provided_subscription_domain" ]; then
    subscription_domain="$provided_subscription_domain"
  else
    subscription_domain=""
  fi

  while ! validate_domain "$subscription_domain" || [ "$subscription_domain" = "$panel_domain" ]; do
    if [ "$subscription_domain" = "$panel_domain" ] && [ -n "$subscription_domain" ]; then
      warn "Subscription page domain must be different from Panel domain. Try again."
    fi
    ask_validated "Subscription page domain, for example sub.example.com" subscription_domain validate_domain "Enter a valid domain without https:// or a path." "$subscription_domain_default" || return $?
  done

  webserver="${WEBSERVER:-}"
  letsencrypt_email="${LETSENCRYPT_EMAIL:-}"

  if [ -z "$webserver" ]; then
    menu_title "Select reverse proxy for subscription page"
    menu_item 1 "Caddy, automatic certificate"
    menu_item 2 "NGINX + Certbot"
    menu_item 3 "Do not configure reverse proxy"

    blank

    ask_choice "Selection" webserver 1 3 "1" || return $?

    case "$webserver" in
      1) webserver="caddy" ;;
      2) webserver="nginx" ;;
      3) webserver="none" ;;
    esac
  fi

  if [ "$webserver" != "none" ]; then
    section "DNS check"

    check_domain_dns "$subscription_domain"

    if [ -z "$letsencrypt_email" ]; then
      ask "Email for Let's Encrypt/Caddy (can be empty)" letsencrypt_email ""
    fi
  fi

  get_panel_api_token "$panel_base" token

  cd "$PANEL_DIR"

  if [ -f .env ]; then
    current_sub_public_domain="$(grep -E '^SUB_PUBLIC_DOMAIN=' .env | tail -n1 | cut -d= -f2- | sed 's/^"//; s/"$//')"

    if [ "$current_sub_public_domain" != "$subscription_domain" ]; then
      should_recreate_panel="1"
    fi

    set_env_value .env "SUB_PUBLIC_DOMAIN" "$subscription_domain"
  fi

  create_subscription_page_service "$panel_base" "$token" "$PANEL_DIR"

  if [ "$should_recreate_panel" = "1" ]; then
    run_cmd_stream "Recreate Remnawave backend after subscription domain update" docker compose -f docker-compose.yml -f docker-compose.subscription.yml up -d --force-recreate remnawave
  fi

  configure_subscription_reverse_proxy "$subscription_domain" "$webserver" "$letsencrypt_email"

  save_panel_state "$panel_domain" "$webserver" "$letsencrypt_email" "$subscription_domain"

  check_subscription_page_url "$subscription_domain" "$webserver"
}

# SUBSCRIPTION_PAGE END

# NODE BEGIN

print_node_summary() {
  local node_port="$1"

  section "Completed: Remnawave Node"
  summary_item "Directory" "${NODE_DIR}"
  summary_item "Compose" "${NODE_DIR}/docker-compose.yml"
  summary_item "Node API port" "${node_port}"
  summary_item "Node logs" "sudo bash install_remnawave.sh -> Node -> Logs"
  summary_item "Firewall" "open ${node_port}/tcp for the panel IP only."

  blank
}

install_node() {
  local same_server="${1:-}"
  local node_port
  local secret_key
  local panel_ip
  local remnawave_subnet
  local remnawave_gateway
  local env_file
  local panel_base
  local default_panel_base
  local token
  local node_name
  local node_address
  local config_profile_uuid
  local config_profile_name
  local config_json
  local profile_inbounds_json
  local inbound_uuid
  local node_uuid

  section "Install Remnawave Node"

  install_prerequisites

  if [ -d "$NODE_DIR" ] && [ -f "$NODE_DIR/docker-compose.yml" ]; then
    die "${NODE_DIR} already exists. Use update or remove."
  fi

  ask_validated "Node API port" node_port validate_port "Enter a port from 1 to 65535." "2222"
  while [[ "$node_port" == 0?* ]]; do node_port="${node_port#0}"; done

  if confirm "Create and add this Node in Panel automatically?"; then
    default_panel_base="$(default_panel_api_base)"

    ask_required "Panel API base URL" panel_base "$default_panel_base"

    get_panel_api_token "$panel_base" token

    ask_required "Node name" node_name "node-1"

    if [ "$same_server" = "same-server" ]; then
      remnawave_gateway="$(get_docker_network_gateway remnawave-network)"
      [ -n "$remnawave_gateway" ] || die "Failed to detect remnawave-network gateway for local Panel + Node installation."
      node_address="$remnawave_gateway"
      detail "Using local Docker gateway as Node address for Panel: ${node_address}"
    else
      ask_validated "Node public address/IP" node_address validate_host "Enter a valid IPv4 address or domain, without a URL or path." "$(get_public_ipv4)"
    fi

    validate_host "$node_address" || die "Invalid Node address: ${node_address}"

    select_config_profile "$panel_base" "$token" config_profile_uuid config_profile_name config_json profile_inbounds_json
    select_inbound_from_config "$config_json" inbound_uuid "$profile_inbounds_json"

    create_remnawave_node_api "$panel_base" "$token" "$config_profile_uuid" "$inbound_uuid" "$node_address" "$node_name" "$node_port" secret_key node_uuid

    ok "Node created in Panel: ${node_name} (${node_uuid})."

    if [ -z "$secret_key" ]; then
      note "Panel API did not return SECRET_KEY for the created node. Open the node card in Panel and paste SECRET_KEY manually."
      ask_secret_required "SECRET_KEY from the Remnawave node card" secret_key
    fi
  else
    skip "Automatic Panel node creation skipped by user."
    ask_secret_required "SECRET_KEY from the Remnawave node card" secret_key
  fi

  if [ "$same_server" = "same-server" ]; then
    panel_ip=""
    detail "Panel and Node are on one server. Firewall will allow the local Remnawave Docker network automatically."
  else
    ask_validated "Public panel IP for firewall" panel_ip validate_optional_ipv4 "Enter a valid IPv4 address." "$(get_public_ipv4)"
  fi

  mkdir -p "$NODE_DIR" /var/log/remnanode

  cd "$NODE_DIR"

  env_file="${NODE_DIR}/.env"

  cat > "$env_file" <<EOF
NODE_PORT=${node_port}
SECRET_KEY=${secret_key}
EOF
  chmod 600 "$env_file"

  cat > docker-compose.yml <<EOF
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: remnawave/node:latest
    restart: always
    network_mode: host
    cap_add:
      - NET_ADMIN
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    env_file:
      - ./.env
    volumes:
      - /var/log/remnanode:/var/log/remnanode
EOF

  chmod 600 docker-compose.yml

  cat > /etc/logrotate.d/remnanode <<'EOF'
/var/log/remnanode/*.log {
    size 50M
    rotate 5
    compress
    missingok
    notifempty
    copytruncate
}
EOF

  section "Node startup"

  run_cmd_stream "Start Remnawave Node" docker compose up -d

  if command_exists ufw && ufw status | grep -q "Status: active"; then
    section "Node firewall"
    if [ -n "$panel_ip" ]; then
      run_cmd "Allow Node API from Panel IP" ufw allow from "$panel_ip" to any port "$node_port" proto tcp
    fi

    if docker network inspect remnawave-network >/dev/null 2>&1; then
      remnawave_subnet="$(get_docker_network_subnet remnawave-network)"

      if [ -n "$remnawave_subnet" ]; then
        run_cmd "Allow Node API from local Remnawave Docker network" ufw allow from "$remnawave_subnet" to any port "$node_port" proto tcp
      fi
    fi

    run_cmd "Reload UFW" ufw reload || true
  fi

  if wait_for_compose_service_ready remnanode 30 3; then
    ok "Remnawave Node container is running."
  else
    run_cmd_stream "Show Node compose status after startup failure" docker compose ps || true
    run_cmd_stream "Show recent Node logs after startup failure" docker compose logs --tail=80 remnanode || true

    die "Remnawave Node did not start."
  fi

  note "Node port is open only for the panel IP and local Remnawave Docker network, when detected."

  ok "Node installed in ${NODE_DIR}."

  print_node_summary "$node_port"
}

install_panel_node() {
  note "Panel + Node on one server is suitable for small installations."
  note "For production load, place Panel and Node on separate servers."

  if ! confirm "Continue Panel + Node installation?"; then
    warn "Panel + Node installation cancelled by user."

    return 0
  fi

  install_panel

  printf "\n"

  install_node same-server
}

update_node() {
  section "Update Remnawave Node"

  backup_node

  compose_action "$NODE_DIR" update
}

reinstall_node_keep_config() {
  [ -d "$NODE_DIR" ] || die "Node is not installed."

  backup_all

  note "Node reinstall will keep the current docker-compose.yml."

  if ! confirm "Continue Node reinstall?"; then
    warn "Node reinstall cancelled by user."

    return 0
  fi

  cd "$NODE_DIR"

  section "Reinstall Remnawave Node"

  run_cmd_stream "Stop Node compose stack before reinstall" docker compose down --remove-orphans || true
  run_cmd_stream "Pull Node compose images" docker compose pull
  run_cmd_stream "Start Node compose stack" docker compose up -d

  ok "Node reinstalled with compose preserved."
}

# NODE END

# STACK_REMOVAL BEGIN

remove_stack() {
  local name="$1"
  local dir="$2"

  if [ ! -d "$dir" ]; then
    warn "${name} was not found."

    return 0
  fi

  assert_managed_dir "$dir"

  note "Removing ${name}: ${dir}"
  note "Docker volumes are not removed by default."

  if confirm "Stop containers and remove directory ${dir}?"; then
    if [ -f "${dir}/docker-compose.yml" ]; then
      cd "$dir" || return 1

      if [ -f docker-compose.subscription.yml ]; then
        run_cmd_stream "Stop ${name} compose stack" docker compose -f docker-compose.yml -f docker-compose.subscription.yml down --remove-orphans || return 1
      else
        run_cmd_stream "Stop ${name} compose stack" docker compose down --remove-orphans || return 1
      fi
    fi

    rm -rf "$dir" || return 1

    ok "${name} removed."
  else
    warn "${name} removal cancelled by user."
    return 130
  fi
}

remove_stack_with_volumes() {
  local name="$1"
  local dir="$2"

  local answer

  if [ ! -d "$dir" ]; then
    warn "${name} was not found."

    return 0
  fi

  assert_managed_dir "$dir"

  note "Full removal of ${name} with Docker volumes."

  ask_delete_confirmation answer || return 130

  [ "$answer" = "DELETE" ] || { note "Removal cancelled."; return 130; }

  if [ -f "${dir}/docker-compose.yml" ]; then
    cd "$dir" || return 1

    if [ -f docker-compose.subscription.yml ]; then
      run_cmd_stream "Stop ${name} compose stack and remove volumes" docker compose -f docker-compose.yml -f docker-compose.subscription.yml down -v --remove-orphans || return 1
    else
      run_cmd_stream "Stop ${name} compose stack and remove volumes" docker compose down -v --remove-orphans || return 1
    fi
  fi

  rm -rf "$dir" || return 1

  ok "${name} fully removed."
}

# STACK_REMOVAL END

# SYSTEM BEGIN

status_all() {
  section "Overall status"

  if [ -f "${PANEL_DIR}/docker-compose.yml" ]; then
    step "Panel"

    compose_action "$PANEL_DIR" status
  else
    warn "Panel is not installed."
  fi

  if [ -f "${NODE_DIR}/docker-compose.yml" ]; then
    step "Node"

    compose_action "$NODE_DIR" status
  else
    warn "Node is not installed."
  fi
}

disable_ipv6() {
  cat > /etc/sysctl.d/99-disable-ipv6.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
  run_cmd_stream "Apply sysctl configuration" sysctl --system
  ok "IPv6 disabled via /etc/sysctl.d/99-disable-ipv6.conf."
}

enable_ipv6() {
  rm -f /etc/sysctl.d/99-disable-ipv6.conf
  cat > /etc/sysctl.d/99-enable-ipv6.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
net.ipv6.conf.lo.disable_ipv6 = 0
EOF
  run_cmd_stream "Apply sysctl configuration" sysctl --system
  ok "IPv6 enabled."
}

# SYSTEM END

# WARP BEGIN

wgcf_arch() {
  case "$(uname -m)" in
    x86_64) printf "amd64" ;;
    aarch64|arm64) printf "arm64" ;;
    armv7l) printf "armv7" ;;
    *) printf "amd64" ;;
  esac
}

install_wgcf_binary() {
  local version
  local arch
  local url
  local tmp_file

  if command_exists wgcf; then
    ok "wgcf is already installed."

    return 0
  fi

  version="$(curl -fsSL https://api.github.com/repos/ViRb3/wgcf/releases/latest | jq -r '.tag_name // empty')"
  [ -n "$version" ] || die "Failed to detect latest wgcf release."

  arch="$(wgcf_arch)"
  url="https://github.com/ViRb3/wgcf/releases/download/${version}/wgcf_${version#v}_linux_${arch}"
  tmp_file="$(mktemp)"

  run_cmd_stream "Download wgcf ${version} (${arch})" curl -fsSL "$url" -o "$tmp_file"
  chmod +x "$tmp_file"
  install -m 0755 "$tmp_file" /usr/local/bin/wgcf
  rm -f "$tmp_file"

  ok "wgcf ${version} installed."
}

prepare_warp_config() {
  local source_conf="$1"

  [ -f "$source_conf" ] || die "Missing wgcf profile: ${source_conf}"

  sed -i '/^DNS =/d' "$source_conf"

  if ! grep -q '^Table = off$' "$source_conf"; then
    sed -i '/^MTU =/aTable = off' "$source_conf"
  fi

  if ! grep -q '^PersistentKeepalive = 25$' "$source_conf"; then
    sed -i '/^Endpoint =/aPersistentKeepalive = 25' "$source_conf"
  fi

  sed -i 's/,[[:space:]]*[0-9a-fA-F:]\+\/128//g' "$source_conf"
  sed -i '/^Address = [0-9a-fA-F:]\+\/128/d' "$source_conf"

  mkdir -p /etc/wireguard
  install -m 600 "$source_conf" "$WARP_CONF"
}

stop_official_warp_client_if_present() {
  if command_exists warp-cli; then
    run_cmd_stream "Disconnect official Cloudflare WARP client" timeout 30 warp-cli --accept-tos disconnect || true
  fi

  if systemctl list-unit-files warp-svc.service >/dev/null 2>&1; then
    run_cmd "Stop official Cloudflare WARP service" systemctl stop warp-svc || true
    run_cmd "Disable official Cloudflare WARP service" systemctl disable warp-svc || true
  fi
}

install_warp_native() {
  local work_dir="$WARP_NATIVE_DIR"
  local license_key=""

  stop_official_warp_client_if_present
  install_base_packages
  run_cmd_stream "Install WireGuard packages" apt-get install -y wireguard
  install_wgcf_binary

  mkdir -p "$work_dir"
  cd "$work_dir"

  ask_secret "WARP+ license key (optional, press Enter to skip)" license_key

  if [ -n "$license_key" ]; then
    rm -f wgcf-account.toml wgcf-profile.conf
  fi

  if [ ! -f wgcf-account.toml ]; then
    if ! run_cmd_stream "Register wgcf account" bash -c 'yes | timeout 90 wgcf register'; then
      [ -f wgcf-account.toml ] || die "wgcf registration failed and wgcf-account.toml was not created."
      warn "wgcf registration returned an error, but account file was created. Continuing."
    fi
  else
    ok "wgcf account already exists."
  fi

  if [ -n "$license_key" ]; then
    run_cmd_stream "Apply WARP+ license" wgcf update --license-key "$license_key" || warn "WARP+ license was not applied; continuing with free WARP."
  fi

  run_cmd_stream "Generate wgcf profile" wgcf generate
  prepare_warp_config "${work_dir}/wgcf-profile.conf"

  run_cmd_stream "Start WARP WireGuard interface" systemctl restart wg-quick@warp
  run_cmd "Enable WARP WireGuard autostart" systemctl enable wg-quick@warp

  install_warp_watchdog

  ok "WARP native is installed via wgcf/wg-quick with Table=off."
  note "Default server routes are not changed. Use sockopt interface 'warp' in Xray config profiles."
  show_warp_status
}

enable_warp_native() {
  [ -f "$WARP_CONF" ] || die "Missing ${WARP_CONF}. Run WARP native -> Install/start first."

  run_cmd_stream "Restart WARP WireGuard interface" systemctl restart wg-quick@warp
  run_cmd "Enable WARP WireGuard autostart" systemctl enable wg-quick@warp

  ok "WARP WireGuard interface started."

  show_warp_status
}

disconnect_warp() {
  if systemctl list-unit-files wg-quick@warp.service >/dev/null 2>&1 || [ -f "$WARP_CONF" ]; then
    run_cmd_stream "Stop WARP WireGuard interface" systemctl stop wg-quick@warp || true

    ok "WARP WireGuard interface stopped."
  else
    warn "WARP WireGuard configuration was not found."
  fi
}

remove_warp() {
  disconnect_warp

  stop_official_warp_client_if_present

  run_cmd "Disable WARP WireGuard autostart" systemctl disable wg-quick@warp || true

  rm -f "$WARP_CONF"
  rm -rf "$WARP_NATIVE_DIR"
  rm -f /usr/local/bin/wgcf
  rm -f /etc/cron.d/warp-native
  rm -f /usr/local/bin/warp
  ok "WARP native removed."
}

install_warp_watchdog() {
  mkdir -p "${WARP_NATIVE_DIR}/logs"

  cat > "${WARP_NATIVE_DIR}/config.env" <<'EOF'
HANDSHAKE_THRESHOLD=180
RESTART_COOLDOWN=120
LOG_MAX_LINES=1000
EOF

  cat > "${WARP_NATIVE_DIR}/warp-watchdog.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG="/opt/warp-native/config.env"
LOG="/opt/warp-native/logs/watchdog.log"
COOLDOWN_FILE="/opt/warp-native/logs/.last_restart"

[ -f "$CONFIG" ] && . "$CONFIG"

HANDSHAKE_THRESHOLD="${HANDSHAKE_THRESHOLD:-180}"
RESTART_COOLDOWN="${RESTART_COOLDOWN:-120}"
LOG_MAX_LINES="${LOG_MAX_LINES:-1000}"

mkdir -p "$(dirname "$LOG")"

log_watchdog() {
  printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" >> "$LOG"
}

rotate_log() {
  [ -f "$LOG" ] || return 0
  
  local lines

  lines=$(wc -l < "$LOG")

  if [ "$lines" -gt "$LOG_MAX_LINES" ]; then
    tail -n "$LOG_MAX_LINES" "$LOG" > "${LOG}.tmp" && mv "${LOG}.tmp" "$LOG"
  fi
}

restart_warp() {
  local reason="$1"
  local now

  now=$(date +%s)

  if [ -f "$COOLDOWN_FILE" ]; then
    local last_restart
    local diff

    last_restart=$(cat "$COOLDOWN_FILE" 2>/dev/null || echo 0)
    diff=$((now - last_restart))

    if [ "$diff" -lt "$RESTART_COOLDOWN" ]; then
      log_watchdog "SKIP" "Restart skipped (${diff}s < ${RESTART_COOLDOWN}s). Reason: ${reason}"

      return 0
    fi
  fi

  log_watchdog "RESTART" "Restarting wg-quick@warp. Reason: ${reason}"

  systemctl restart wg-quick@warp && log_watchdog "OK" "wg-quick@warp restarted" || log_watchdog "ERROR" "wg-quick@warp restart failed"

  date +%s > "$COOLDOWN_FILE"
}

rotate_log

if ! systemctl is-active --quiet wg-quick@warp; then
  restart_warp "systemd unit is not active"

  exit 0
fi

handshake_ts=$(wg show warp latest-handshakes 2>/dev/null | awk '{print $2}')
if [ -z "$handshake_ts" ] || [ "$handshake_ts" -eq 0 ]; then
  restart_warp "no handshake data"
  exit 0
fi

age=$(($(date +%s) - handshake_ts))
if [ "$age" -gt "$HANDSHAKE_THRESHOLD" ]; then
  restart_warp "handshake too old (${age}s > ${HANDSHAKE_THRESHOLD}s)"
  exit 0
fi

if ! ping -I warp -c 2 -W 3 1.1.1.1 >/dev/null 2>&1; then
  restart_warp "ping via warp interface failed"
  exit 0
fi

log_watchdog "OK" "WARP is healthy (handshake ${age}s ago)"
EOF

  chmod +x "${WARP_NATIVE_DIR}/warp-watchdog.sh"

  cat > /etc/cron.d/warp-native <<'EOF'
# remnawave installer WARP native watchdog
*/10 * * * * root /opt/warp-native/warp-watchdog.sh
EOF
  chmod 644 /etc/cron.d/warp-native

  cat > /usr/local/bin/warp <<'EOF'
#!/usr/bin/env bash
case "${1:-status}" in
  start) systemctl start wg-quick@warp ;;
  stop) systemctl stop wg-quick@warp ;;
  restart) systemctl restart wg-quick@warp ;;
  log) tail -f /opt/warp-native/logs/watchdog.log ;;
  status|*) systemctl status wg-quick@warp --no-pager; wg show warp || true ;;
esac
EOF
  chmod +x /usr/local/bin/warp

  ok "WARP watchdog installed."
}

show_warp_status() {
  section "WARP native status"

  if [ ! -f "$WARP_CONF" ]; then
    warn "WARP WireGuard configuration is not installed."

    return 0
  fi

  run_cmd_stream "Show wg-quick@warp status" systemctl status wg-quick@warp --no-pager || true
  run_cmd_stream "Show WARP WireGuard handshake" wg show warp || true
  run_cmd_stream "Show WARP interface" ip address show dev warp || true
  run_cmd_stream "Show Cloudflare trace via WARP interface" bash -c "curl -fsSL --interface warp --max-time 10 https://www.cloudflare.com/cdn-cgi/trace | grep -E 'warp=|ip='" || true
  run_cmd_stream "Show default route" ip -4 route show default || true
}

select_config_profile() {
  local panel_base="$1"
  local token="$2"
  local uuid_var="$3"
  local name_var="$4"
  local config_var="$5"
  local inbounds_var="${6:-}"

  local response
  local choice

  local idx=1

  local profile_count
  local selected_json

  response=$(make_panel_api_request "GET" "$panel_base" "$token" "/api/config-profiles")

  profile_count=$(printf "%s\n" "$response" | jq '.response.configProfiles | length')

  [ "$profile_count" -gt 0 ] || die "Config profiles were not found."

  menu_title "Config profiles"

  while read -r profile; do
    menu_item \
      "$idx" \
      "$(printf '%s' "$profile" | base64 -d | jq -r '.name') ($(printf '%s' "$profile" | base64 -d | jq -r '.uuid'))"
    idx=$((idx + 1))
  done < <(printf "%s\n" "$response" | jq -r '.response.configProfiles[] | @base64')

  blank

  ask_choice "Selection profile" choice 1 "$profile_count" "1"

  local selected

  selected=$(printf "%s\n" "$response" | jq -r ".response.configProfiles[$((choice - 1))] | @base64")
  selected_json="$(printf '%s' "$selected" | base64 -d)"

  printf -v "$uuid_var" '%s' "$(printf '%s' "$selected_json" | jq -r '.uuid')"
  printf -v "$name_var" '%s' "$(printf '%s' "$selected_json" | jq -r '.name')"
  printf -v "$config_var" '%s' "$(printf '%s' "$selected_json" | jq -c '.config')"

  if [ -n "$inbounds_var" ]; then
    printf -v "$inbounds_var" '%s' "$(printf '%s' "$selected_json" | jq -c '
      .inbounds //
      .activeInbounds //
      .configProfile.inbounds //
      .configProfile.activeInbounds //
      []
    ')"
  fi
}

select_inbound_from_config() {
  local config_json="$1"
  local uuid_var="$2"
  local profile_inbounds_json="${3:-[]}"

  local inbound_count
  local choice
  local selected

  inbound_count=$(jq -n --argjson profileInbounds "$profile_inbounds_json" --argjson config "$config_json" '
    def inbound_items:
      .[]? |
      if type == "string" then {uuid: .}
      elif type == "object" and .uuid != null then .
      else empty
      end;
    [
      ($profileInbounds | inbound_items),
      ($config.inbounds[]? | select(.uuid != null))
    ] as $uuidInbounds |
    if ($uuidInbounds | length) > 0 then
      $uuidInbounds
    else
      [$config.inbounds[]? | select(.tag != null)]
    end |
    length
  ')

  if [ "$inbound_count" -le 0 ] 2>/dev/null; then
    warn "No inbounds with uuid were found in the selected config profile metadata."
    ask_required "Inbound UUID" selected
    printf -v "$uuid_var" '%s' "$selected"

    return 0
  fi

  menu_title "Inbounds"

  jq -n --argjson profileInbounds "$profile_inbounds_json" --argjson config "$config_json" -r '
    def inbound_items:
      .[]? |
      if type == "string" then {uuid: .}
      elif type == "object" and .uuid != null then .
      else empty
      end;
    [
      ($profileInbounds | inbound_items),
      ($config.inbounds[]? | select(.uuid != null))
    ] as $uuidInbounds |
    if ($uuidInbounds | length) > 0 then
      $uuidInbounds
    else
      [$config.inbounds[]? | select(.tag != null)]
    end |
    to_entries[] |
    "\(.key + 1)|\(.value.tag // .value.remark // .value.protocol // "inbound") (\(.value.uuid // "missing uuid"))"
  ' | while IFS='|' read -r key label; do
    menu_item "$key" "$label"
  done
  
  blank

  ask_choice "Selection inbound" choice 1 "$inbound_count" "1"

  selected=$(jq -n --argjson profileInbounds "$profile_inbounds_json" --argjson config "$config_json" -r "
    def inbound_items:
      .[]? |
      if type == \"string\" then {uuid: .}
      elif type == \"object\" and .uuid != null then .
      else empty
      end;
    [
      (\$profileInbounds | inbound_items),
      (\$config.inbounds[]? | select(.uuid != null))
    ] as \$uuidInbounds |
    (
      if (\$uuidInbounds | length) > 0 then
        \$uuidInbounds
      else
        [\$config.inbounds[]? | select(.tag != null)]
      end
    )[$((choice - 1))] | .uuid // empty
  ")

  [ -n "$selected" ] && [ "$selected" != "null" ] || die "Selected inbound does not have UUID. Remnawave API requires inbound UUID."

  printf -v "$uuid_var" '%s' "$selected"
}

update_config_profile_json() {
  local panel_base="$1"
  local token="$2"
  local profile_uuid="$3"
  local config_json="$4"

  local body

  body=$(jq -n --arg uuid "$profile_uuid" --argjson config "$config_json" '{uuid:$uuid,config:$config}')

  make_panel_api_request "PATCH" "$panel_base" "$token" "/api/config-profiles" "$body" >/dev/null
}

add_warp_to_config_profile() {
  local panel_base
  local default_panel_base
  local token
  local profile_uuid
  local profile_name
  local config_json

  default_panel_base="$(default_panel_api_base)"

  ask_required "Panel API base URL" panel_base "$default_panel_base"

  if ! ip link show warp >/dev/null 2>&1; then
    warn "Interface 'warp' is not available right now."
    note "The profile rule uses sockopt interface 'warp'; traffic will fail until WARP native is connected on the node."
    confirm "Add WARP rule to the config profile anyway?" || {
      warn "WARP profile update cancelled."

      return 0
    }
  fi

  get_panel_api_token "$panel_base" token
  select_config_profile "$panel_base" "$token" profile_uuid profile_name config_json

  if printf "%s\n" "$config_json" | jq -e '.outbounds[]? | select(.tag == "warp-out")' >/dev/null 2>&1; then
    warn "warp-out already exists in profile ${profile_name}."
  else
    config_json=$(printf "%s\n" "$config_json" | jq '
      .outbounds = (.outbounds // []) +
      [{
        "tag": "warp-out",
        "protocol": "freedom",
        "settings": {
          "domainStrategy": "UseIP"
        },
        "streamSettings": {
          "sockopt": {
            "interface": "warp",
            "tcpFastOpen": true
          }
        }
      }]')
  fi

  if printf "%s\n" "$config_json" | jq -e '.routing.rules[]? | select(.outboundTag == "warp-out")' >/dev/null 2>&1; then
    warn "warp rule already exists in routing rules for profile ${profile_name}."
  else
    config_json=$(printf "%s\n" "$config_json" | jq '
      .routing = (.routing // {}) |
      .routing.rules = (.routing.rules // []) +
      [{
        "type": "field",
        "domain": ["browserleaks.com"],
        "outboundTag": "warp-out"
      }]')
  fi

  update_config_profile_json "$panel_base" "$token" "$profile_uuid" "$config_json"

  ok "WARP added to config profile ${profile_name}."
}

remove_warp_from_config_profile() {
  local panel_base
  local default_panel_base
  local token
  local profile_uuid
  local profile_name
  local config_json

  default_panel_base="$(default_panel_api_base)"

  ask_required "Panel API base URL" panel_base "$default_panel_base"

  get_panel_api_token "$panel_base" token
  select_config_profile "$panel_base" "$token" profile_uuid profile_name config_json

  config_json=$(printf "%s\n" "$config_json" | jq '
    if .outbounds then
      del(.outbounds[] | select(.tag == "warp-out"))
    else
      .
    end |
    if .routing.rules then
      del(.routing.rules[] | select(.outboundTag == "warp-out"))
    else
      .
    end')

  update_config_profile_json "$panel_base" "$token" "$profile_uuid" "$config_json"

  ok "WARP removed from config profile ${profile_name}."
}

# WARP END

# MENUS BEGIN

# Call this and its enclosing menus as simple commands, never in if/! or ||.
# Testing a Bash function's status would disable errexit throughout its body.
run_menu_action() {
  local action_status
  local restore_errexit=0
  local previous_int_trap
  [[ "$-" != *e* ]] || restore_errexit=1
  previous_int_trap="$(trap -p INT)"

  trap ':' INT
  set +e
  (
    set -Eeuo pipefail
    trap 'exit 130' INT
    "$@"
  )
  action_status=$?
  if [ -n "$previous_int_trap" ]; then
    eval "$previous_int_trap"
  else
    trap - INT
  fi
  if [ "$restore_errexit" = 1 ]; then set -e; fi

  case "$action_status" in
    0) ;;
    130) note "Operation cancelled. Returning to the menu." ;;
    *)
      warn "Operation stopped (exit ${action_status}). See the error above or ${LOG_FILE}."
      note "Returning to the menu. Completed steps are preserved; retry the failed operation when ready."
      ;;
  esac
  return 0
}

show_main_menu() {
  menu_title "Remnawave installer ${SCRIPT_VERSION}"
  menu_item 1 "Install"
  menu_item 2 "Panel"
  menu_item 3 "Node"
  menu_item 4 "System"
  menu_item 5 "WARP native"
  menu_item 6 "Certificates"
  menu_item 7 "Backup / Restore"
  menu_item_accent 8 "Support Creator"
  menu_item 0 "Exit"
  blank
}

show_install_menu() {
  menu_title "Install"
  menu_item 1 "Install Panel"
  menu_item 2 "Install Node"
  menu_item 3 "Install Panel + Node"
  menu_item 0 "Back"
  blank
}

show_panel_menu() {
  menu_title "Panel"
  menu_item 1 "Start"
  menu_item 2 "Stop"
  menu_item 3 "Restart"
  menu_item 4 "Update"
  menu_item 5 "Status"
  menu_item 6 "Logs"
  menu_item 7 "Reinstall preserving .env/volumes"
  menu_item 8 "Remove without volumes"
  menu_item 9 "Remove with volumes"
  menu_item 10 "Configure subscription page"
  menu_item 11 "Create Panel admin"
  menu_item 0 "Back"
  blank
}

show_node_menu() {
  menu_title "Node"
  menu_item 1 "Start"
  menu_item 2 "Stop"
  menu_item 3 "Restart"
  menu_item 4 "Update"
  menu_item 5 "Status"
  menu_item 6 "Logs"
  menu_item 7 "Reinstall preserving compose"
  menu_item 8 "Remove without volumes"
  menu_item 9 "Remove with volumes"
  menu_item 0 "Back"
  blank
}

show_system_menu() {
  menu_title "System"
  menu_item 1 "Overall status"
  menu_item 2 "Disable IPv6"
  menu_item 3 "Enable IPv6"
  menu_item 0 "Back"
  blank
}

show_warp_menu() {
  menu_title "WARP native"
  menu_item 1 "Install and start"
  menu_item 2 "Restart"
  menu_item 3 "Stop"
  menu_item 4 "Remove"
  menu_item 5 "Status"
  menu_item 6 "Add to node routing"
  menu_item 7 "Remove from node routing"
  menu_item 0 "Back"
  blank
}

show_cert_menu() {
  menu_title "Certificates"
  menu_item 1 "Issue Cloudflare DNS-01 wildcard"
  menu_item 2 "Issue Gcore DNS-01 wildcard"
  menu_item 3 "List certificates"
  menu_item 4 "Run renew dry-run"
  menu_item 5 "Configure certbot auto-renew for NGINX"
  menu_item 6 "Remove installer certbot cron"
  menu_item 0 "Back"
  blank
}

show_backup_menu() {
  menu_title "Backup / Restore"
  menu_item 1 "Create full backup"
  menu_item 2 "Restore from backup"
  menu_item 0 "Back"
  blank
}

print_support_creator_details() {
  log "${CYAN}  This installer is free and maintained in spare time.${RESET}"
  log "${CYAN}  If it saved you time, helped with deployment, or you want to support future updates,${RESET}"
  log "${CYAN}  you can support the creator using any option below.${RESET}"
  blank

  summary_item "BTC" "bc1quktsqka8g3tgd5thz8y2n93v2n8xga8yk5acd7"
  summary_item "ETH" "0x54fA3BAd92643EcDD599717F61515499cB493bb6"
  summary_item "ERC20/BEP20" "0x54fA3BAd92643EcDD599717F61515499cB493bb6"
  summary_item "SOL" "DvULVG6Wi5ABLhr9UBHup6CJrQUsrnufjqwBiZGEgTWz"
  summary_item "ZEC" "t1TP7jQyFVs5LFzqVv7hPfZYfHPMrTcuyC4"
  summary_item "Tribute" "https://t.me/tribute/app?startapp=dMLC"
  summary_item "DonationAlerts" "https://donationalerts.com/r/cluedesc"
  blank
}

show_support_creator() {
  menu_title "${MAGENTA}Support Creator${RESET}"
  print_support_creator_details

  prompt_line "Press Enter to return to the menu..."
  read_input >/dev/null
  blank
}

show_startup_support_notice() {
  if [ -f "$SUPPORT_NOTICE_FILE" ]; then
    return 0
  fi

  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"

  blank
  log "${MAGENTA}============================================================${RESET}"
  log "${MAGENTA}                      Support Creator                      ${RESET}"
  log "${MAGENTA}============================================================${RESET}"
  print_support_creator_details
  log "${GRAY}  You can always reopen this screen from the main menu:${RESET} ${CYAN}Support Creator${RESET}"
  log "${MAGENTA}============================================================${RESET}"
  blank

  prompt_line "Press Enter to continue..."
  read_input >/dev/null
  blank

  touch "$SUPPORT_NOTICE_FILE"
  chmod 600 "$SUPPORT_NOTICE_FILE"
}

handle_install_menu() {
  local choice

  while true; do
    show_install_menu
    ask_menu_choice choice || return 0
    case "$choice" in
      1) run_menu_action install_panel ;;
      2) run_menu_action install_node ;;
      3) run_menu_action install_panel_node ;;
      0) return 0 ;;
      *) warn "Invalid menu item." ;;
    esac
  done
}

handle_panel_menu() {
  local choice

  while true; do
    show_panel_menu
    ask_menu_choice choice || return 0
    case "$choice" in
      1) run_menu_action compose_action "$PANEL_DIR" start ;;
      2) run_menu_action compose_action "$PANEL_DIR" stop ;;
      3) run_menu_action compose_action "$PANEL_DIR" restart ;;
      4) run_menu_action update_panel ;;
      5) run_menu_action compose_action "$PANEL_DIR" status ;;
      6) run_menu_action compose_action "$PANEL_DIR" logs ;;
      7) run_menu_action reinstall_panel_keep_config ;;
      8) run_menu_action remove_panel ;;
      9) run_menu_action remove_panel_with_volumes ;;
      10) run_menu_action setup_subscription_page_for_panel ;;
      11) run_menu_action create_admin_for_existing_panel ;;
      0) return 0 ;;
      *) warn "Invalid menu item." ;;
    esac
  done
}

handle_node_menu() {
  local choice

  while true; do
    show_node_menu
    ask_menu_choice choice || return 0
    case "$choice" in
      1) run_menu_action compose_action "$NODE_DIR" start ;;
      2) run_menu_action compose_action "$NODE_DIR" stop ;;
      3) run_menu_action compose_action "$NODE_DIR" restart ;;
      4) run_menu_action update_node ;;
      5) run_menu_action compose_action "$NODE_DIR" status ;;
      6) run_menu_action compose_action "$NODE_DIR" logs ;;
      7) run_menu_action reinstall_node_keep_config ;;
      8) run_menu_action remove_stack "Node" "$NODE_DIR" ;;
      9) run_menu_action remove_stack_with_volumes "Node" "$NODE_DIR" ;;
      0) return 0 ;;
      *) warn "Invalid menu item." ;;
    esac
  done
}

handle_system_menu() {
  local choice

  while true; do
    show_system_menu
    ask_menu_choice choice || return 0
    case "$choice" in
      1) run_menu_action status_all ;;
      2) run_menu_action disable_ipv6 ;;
      3) run_menu_action enable_ipv6 ;;
      0) return 0 ;;
      *) warn "Invalid menu item." ;;
    esac
  done
}

handle_warp_menu() {
  local choice

  while true; do
    show_warp_menu
    ask_menu_choice choice || return 0
    case "$choice" in
      1) run_menu_action install_warp_native ;;
      2) run_menu_action enable_warp_native ;;
      3) run_menu_action disconnect_warp ;;
      4) run_menu_action remove_warp ;;
      5) run_menu_action show_warp_status ;;
      6) run_menu_action add_warp_to_config_profile ;;
      7) run_menu_action remove_warp_from_config_profile ;;
      0) return 0 ;;
      *) warn "Invalid menu item." ;;
    esac
  done
}

handle_cert_menu() {
  local choice

  while true; do
    show_cert_menu
    ask_menu_choice choice || return 0
    case "$choice" in
      1) run_menu_action issue_cloudflare_wildcard_cert ;;
      2) run_menu_action issue_gcore_wildcard_cert ;;
      3) run_menu_action list_certificates ;;
      4) run_menu_action renew_certificates_dry_run ;;
      5) run_menu_action setup_certbot_auto_renew "nginx" ;;
      6) run_menu_action remove_certbot_renew_cron ;;
      0) return 0 ;;
      *) warn "Invalid menu item." ;;
    esac
  done
}

handle_backup_menu() {
  local choice
  
  while true; do
    show_backup_menu
    ask_menu_choice choice || return 0
    case "$choice" in
      1) run_menu_action backup_all ;;
      2) run_menu_action restore_backup ;;
      0) return 0 ;;
      *) warn "Invalid menu item." ;;
    esac
  done
}

# MENUS END

# ENTRYPOINT BEGIN

main() {
  need_root

  check_os

  prepare_log

  show_startup_support_notice

  local choice

  while true; do
    show_main_menu

    ask_menu_choice choice || return 0

    case "$choice" in
      1) handle_install_menu ;;
      2) handle_panel_menu ;;
      3) handle_node_menu ;;
      4) handle_system_menu ;;
      5) handle_warp_menu ;;
      6) handle_cert_menu ;;
      7) handle_backup_menu ;;
      8) run_menu_action show_support_creator ;;
      0) exit 0 ;;
      *) warn "Invalid menu item." ;;
    esac
  done
}

# ENTRYPOINT END

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
