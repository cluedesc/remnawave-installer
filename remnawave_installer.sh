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

# Enabled by the entrypoint; sourcing the file is side-effect free for callers/tests.
OPERATION_TRACKING_ENABLED=0
OPERATION_ACTIVE=0

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
  operation_set_step "$*"
  blank

  log "${GREEN}==>${RESET} $*"
}

step() { operation_set_step "$*"; log "${GREEN}  -${RESET} $*"; }

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

navigation_status() {
  case "$1" in
    /cancel) return 130 ;;
    /back) return 131 ;;
    *) return 0 ;;
  esac
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

    __ask_value="$(read_input)" || return $?

    __ask_value="${__ask_value:-$__ask_default_value}"
  else
    prompt_line "$__ask_prompt: "

    __ask_value="$(read_input)" || return $?
  fi

  __ask_value="$(printf "%s" "$__ask_value" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"

  navigation_status "$__ask_value" || return $?

  printf -v "$__ask_var_name" '%s' "$__ask_value"
}

ask_secret() {
  local __ask_secret_prompt="$1"
  local __ask_secret_var_name="$2"
  local __ask_secret_show_empty_note="${3:-1}"

  local __ask_secret_value=""

  prompt_line "$__ask_secret_prompt: "

  local __ask_secret_status=0
  __ask_secret_value="$(read_secret_input)" || __ask_secret_status=$?
  if [ "$__ask_secret_status" -ne 0 ]; then printf "\n"; return "$__ask_secret_status"; fi

  printf "\n"

  __ask_secret_value="$(printf "%s" "$__ask_secret_value" | tr -d '\r')"

  if [ -n "$__ask_secret_value" ]; then
    micro "input hidden"
  elif [ "$__ask_secret_show_empty_note" = "1" ]; then
    note "Secret value is empty."
  fi

  navigation_status "$__ask_secret_value" || return $?

  printf -v "$__ask_secret_var_name" '%s' "$__ask_secret_value"
}

ask_required() {
  local __ask_required_prompt="$1"
  local __ask_required_var_name="$2"
  local __ask_required_value=""

  while true; do
    if [ "$#" -ge 3 ]; then
      ask "$__ask_required_prompt" __ask_required_value "$3" || return $?
    else
      ask "$__ask_required_prompt" __ask_required_value || return $?
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
    ask_secret "$__ask_secret_required_prompt" __ask_secret_required_value 0 || return $?

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
    ask "$1" __ask_validated_value "${5:-}" || return $?
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
    ask "$1" __ask_choice_value "${5:-}" || return $?
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

  local read_status=0
  answer="$(read_input)" || read_status=$?
  if [ "$read_status" -ne 0 ]; then
    if [ "${OPERATION_ACTIVE:-0}" = 1 ]; then exit "$read_status"; fi
    return "$read_status"
  fi

  normalized="$(printf "%s" "$answer" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | tr '[:upper:]' '[:lower:]')"

  local navigation_result=0
  navigation_status "$normalized" || navigation_result=$?
  if [ "$navigation_result" -ne 0 ]; then
    # Legacy callers use confirm in if/! and cannot propagate cancellation.
    if [ "${OPERATION_ACTIVE:-0}" = 1 ]; then exit "$navigation_result"; fi
    return "$navigation_result"
  fi

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
  __ask_menu_choice_value="$(read_input)" || return $?
  __ask_menu_choice_value="$(printf "%s" "$__ask_menu_choice_value" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"

  navigation_status "$__ask_menu_choice_value" || return $?

  printf -v "$__ask_menu_choice_var_name" '%s' "$__ask_menu_choice_value"
}

ask_delete_confirmation() {
  local __ask_delete_confirmation_var_name="$1"

  local __ask_delete_confirmation_value=""

  prompt_line "Type DELETE to confirm: "
  __ask_delete_confirmation_value="$(read_input)" || return $?
  __ask_delete_confirmation_value="$(printf "%s" "$__ask_delete_confirmation_value" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"

  navigation_status "$__ask_delete_confirmation_value" || return $?

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

validate_url() {
  local url="$1" authority host port
  [[ "$url" =~ ^https?://[^/?#]+(/[^?#]*)?$ ]] || return 1
  [[ ! "$url" =~ [[:space:][:cntrl:]] && "$url" != *\\* ]] || return 1
  authority="${url#*://}"
  authority="${authority%%/*}"
  [[ "$authority" != *@* ]] || return 1
  host="${authority%%:*}"
  if [[ "$authority" == *:* ]]; then
    port="${authority#*:}"
    validate_port "$port" || return 1
  fi
  [ "$host" = localhost ] || validate_host "$host"
}

validate_email() {
  local email="$1" local_part domain
  [ "${#email}" -le 254 ] || return 1
  [[ "$email" == *@* ]] || return 1
  local_part="${email%@*}"
  domain="${email##*@}"
  [ "${#local_part}" -le 64 ] || return 1
  [[ "$local_part" =~ ^[A-Za-z0-9.!\#$%\&\'*+/=?^_\`{|}~-]+$ ]] || return 1
  [[ "$local_part" != .* && "$local_part" != *. && "$local_part" != *..* ]] || return 1
  validate_domain "$domain"
}

validate_optional_email() {
  [ -z "$1" ] || validate_email "$1"
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

  run_cmd_stream "Update apt package index" apt-get update || return 1

  run_cmd_stream "Install required base packages" apt-get install -y ca-certificates curl gnupg openssl jq ufw logrotate apt-transport-https lsb-release dnsutils || return 1
}

install_docker() {
  if command_exists docker && docker compose version >/dev/null 2>&1; then
    ok "Docker and Docker Compose are already installed."

    return 0
  fi

  section "Docker"

  install -m 0755 -d /etc/apt/keyrings || return 1
  run_cmd_stream "Install Docker apt repository key" bash -c 'curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --yes --dearmor -o /etc/apt/keyrings/docker.gpg' || return 1
  chmod a+r /etc/apt/keyrings/docker.gpg || return 1

  local codename architecture

  codename="$(. /etc/os-release && echo "${VERSION_CODENAME}")" || return 1
  architecture=$(dpkg --print-architecture) || return 1

  echo "deb [arch=${architecture} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${codename} stable" > /etc/apt/sources.list.d/docker.list || return 1

  run_cmd_stream "Update apt package index for Docker" apt-get update || return 1

  run_cmd_stream "Install Docker packages" apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || return 1

  run_cmd "Enable and start Docker" systemctl enable --now docker || return 1

  run_cmd "Verify Docker daemon" bash -c 'docker info >/dev/null' || return 1
}

install_prerequisites() {
  install_base_packages || return 1

  install_docker || return 1
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
  [ ! -L "$BACKUP_ROOT" ] || return 1
  mkdir -p "$BACKUP_ROOT" || return 1
  chmod 700 "$BACKUP_ROOT" || return 1
  backup_lock || return 1
  if [ "${BACKUP_SCHEDULED_RUN:-0}" = 1 ]; then
    backup_load_schedule || return 1
    [ "$BACKUP_FREQUENCY" != off ] || return 0
  fi
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
  mkdir "$stage/verify" || return 1
  backup_unpack_verified "$stage/archive.tar.gz" "$stage/verify" || {
    warn "Backup validation failed; no backup created."; return 1;
  }
  backup_release_database || return 1
  mv -- "$stage/archive.tar.gz" "$archive" || return 1
  [ ! -L "$BACKUP_ROOT/.verified" ] || return 1
  mkdir -p "$BACKUP_ROOT/.verified" "$STATE_DIR" || return 1
  chmod 700 "$BACKUP_ROOT/.verified" "$STATE_DIR" || return 1
  printf '%s\n' "$(date +%s)" > "$BACKUP_ROOT/.verified/${archive##*/}.status" || return 1
  printf 'status=success\ntimestamp=%s\narchive=%s\n' "$(date +%s)" "$archive" > "$STATE_DIR/last-backup.status.tmp" || return 1
  chmod 600 "$STATE_DIR/last-backup.status.tmp" || return 1
  mv -- "$STATE_DIR/last-backup.status.tmp" "$STATE_DIR/last-backup.status" || return 1
  backup_prune "$archive" || return 1
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

backup_unpack_verified() {
  local archive="$1" stage="$2" name has_panel
  [ -f "$archive" ] && [ ! -L "$archive" ] || return 1
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
  printf '%s\n' "$has_panel" > "$stage/panel-status"
}

verify_backup() (
  local archive="${1:-}" stage
  [ -n "$archive" ] || select_backup_archive archive || return $?
  umask 077
  stage="$(mktemp -d)" || return 1
  trap 'rm -rf -- "$stage"' EXIT
  backup_unpack_verified "$archive" "$stage" || { warn "Backup verification failed."; return 1; }
  ok "Backup verified: $archive"
)

restore_backup() (
  local archive stage has_panel
  select_backup_archive archive || return $?
  umask 077
  backup_lock || return 1
  stage="$(mktemp -d)" || return 1
  trap 'rm -rf -- "$stage"' EXIT
  backup_unpack_verified "$archive" "$stage" || return 1
  has_panel="$(cat "$stage/panel-status")"
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

# Descriptor locks release automatically on every success, failure and signal.
backup_lock() {
  mkdir -p "$BACKUP_ROOT" || return 1
  [ ! -L "$BACKUP_ROOT/.operation.lock" ] || return 1
  exec 9>"$BACKUP_ROOT/.operation.lock" || return 1
  flock -n 9 || { warn "Another backup or restore is running."; return 1; }
}

backup_archive_paths() {
  local file
  for file in "$BACKUP_ROOT"/remnawave-backup-*.tar.gz; do
    [[ "${file##*/}" =~ ^remnawave-backup-[0-9]{14}-[a-zA-Z0-9]+\.tar\.gz$ ]] || continue
    [ -f "$file" ] && [ ! -L "$file" ] || continue
    printf '%s\n' "$file"
  done | sort -r
}

list_backups() {
  local file index=0
  while IFS= read -r file; do
    index=$((index + 1))
    printf '%s) %s | %s bytes | %s\n' "$index" "$(stat -c '%y' -- "$file")" "$(stat -c '%s' -- "$file")" "${file##*/}"
  done < <(backup_archive_paths)
  [ "$index" -gt 0 ] || printf 'No saved backup archives.\n'
}

select_backup_archive() {
  local output="$1" selection chosen
  local archives=()
  mapfile -t archives < <(backup_archive_paths)
  list_backups
  printf 'm) Enter an archive path manually\n0) Back\n'
  while true; do
    ask "Backup number or m" selection || return $?
    case "$selection" in
      0|/back) return 131 ;;
      /cancel) return 130 ;;
      m|M)
        ask_required "Backup .tar.gz path" chosen || return $?
        ;;
      *)
        if [[ "$selection" =~ ^[1-9][0-9]{0,5}$ ]] && [ "$selection" -le "${#archives[@]}" ]; then
          chosen="${archives[selection-1]}"
        else warn "Select a listed number, m, or 0."; continue; fi
        ;;
    esac
    [ -f "$chosen" ] && [ ! -L "$chosen" ] || { warn "Select an existing regular archive file."; continue; }
    printf -v "$output" '%s' "$chosen"
    return 0
  done
}

backup_load_schedule() {
  BACKUP_FREQUENCY=off BACKUP_TIME=03:00 BACKUP_KEEP=7 BACKUP_DAYS=30
  local key value
  [ -f "$STATE_DIR/backup-schedule.conf" ] || return 0
  [ ! -L "$STATE_DIR/backup-schedule.conf" ] || return 1
  while IFS='=' read -r key value; do
    case "$key" in
      frequency) BACKUP_FREQUENCY="$value" ;;
      time) BACKUP_TIME="$value" ;;
      keep) BACKUP_KEEP="$value" ;;
      days) BACKUP_DAYS="$value" ;;
      *) return 1 ;;
    esac
  done < "$STATE_DIR/backup-schedule.conf"
  [[ "$BACKUP_FREQUENCY" =~ ^(off|daily|weekly)$ ]] &&
    [[ "$BACKUP_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] &&
    [[ "$BACKUP_KEEP" =~ ^(0|[1-9][0-9]{0,4})$ ]] &&
    [[ "$BACKUP_DAYS" =~ ^(0|[1-9][0-9]{0,4})$ ]]
}

backup_schedule_unit_dir() { printf '/etc/systemd/system\n'; }

backup_schedule_systemctl() {
  timeout --kill-after=5 15 systemctl "$@"
}

backup_timer_state() {
  local output key value
  BACKUP_TIMER_ENABLED=unknown BACKUP_TIMER_ACTIVE=unknown BACKUP_TIMER_LOAD=unknown
  output="$(backup_schedule_systemctl show remnawave-installer-backup.timer \
    --property=UnitFileState --property=ActiveState --property=LoadState 2>/dev/null)" || return 1
  while IFS='=' read -r key value; do
    case "$key:$value" in
      UnitFileState:enabled|UnitFileState:disabled|UnitFileState:static|UnitFileState:masked|UnitFileState:indirect)
        BACKUP_TIMER_ENABLED="$value" ;;
      ActiveState:active|ActiveState:inactive|ActiveState:failed) BACKUP_TIMER_ACTIVE="$value" ;;
      LoadState:loaded|LoadState:not-found|LoadState:masked) BACKUP_TIMER_LOAD="$value" ;;
    esac
  done <<< "$output"
  if [ "$BACKUP_TIMER_LOAD" = not-found ]; then
    BACKUP_TIMER_ENABLED=absent
  fi
  [ "$BACKUP_TIMER_ENABLED" != unknown ] && [ "$BACKUP_TIMER_ACTIVE" != unknown ] && [ "$BACKUP_TIMER_LOAD" != unknown ]
}

show_backup_schedule() {
  backup_load_schedule || { warn "Invalid backup schedule configuration."; return 1; }
  printf 'Configured schedule: %s at %s, server local time (%s); weekly runs Monday.\nKeep count: %s; maximum age: %s days (0 disables a limit).\n' \
    "$BACKUP_FREQUENCY" "$BACKUP_TIME" "$(date +%Z)" "$BACKUP_KEEP" "$BACKUP_DAYS"
  backup_timer_state || true
  printf 'Actual timer: enabled=%s; active=%s; unit=%s.\n' "$BACKUP_TIMER_ENABLED" "$BACKUP_TIMER_ACTIVE" "$BACKUP_TIMER_LOAD"
}

backup_prune() {
  local newest="$1" file marker epoch now rank=0
  [ -f "$STATE_DIR/backup-schedule.conf" ] || return 0
  [ ! -L "$BACKUP_ROOT/.verified" ] || return 1
  backup_load_schedule || return 1
  now="$(date +%s)"
  # Only archives successfully verified by this installer have private markers.
  while IFS= read -r file; do
    marker="$BACKUP_ROOT/.verified/${file##*/}.status"
    [ -f "$marker" ] && [ ! -L "$marker" ] || continue
    IFS= read -r epoch < "$marker" || continue
    [[ "$epoch" =~ ^[0-9]{1,12}$ ]] || continue
    rank=$((rank + 1))
    [ "$file" != "$newest" ] || continue
    if { [ "$BACKUP_KEEP" -gt 0 ] && [ "$rank" -gt "$BACKUP_KEEP" ]; } ||
       { [ "$BACKUP_DAYS" -gt 0 ] && [ "$((now - epoch))" -gt "$((BACKUP_DAYS * 86400))" ]; }; then
      rm -- "$file" && rm -- "$marker" || return 1
    fi
  done < <(backup_archive_paths)
}

# Snapshot only backup code and these four nonsecret paths. This works when the
# interactive installer came from process substitution; no runtime download.
backup_write_runner() {
  local function_name variable_name
  printf '#!/usr/bin/env bash\nset -Eeuo pipefail\numask 077\n'
  for variable_name in PANEL_DIR NODE_DIR STATE_DIR BACKUP_ROOT; do
    printf '%s=%q\n' "$variable_name" "${!variable_name}"
  done
  cat <<'RUNNER_HELPERS'
ok() { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }
need_root() { [ "$EUID" = 0 ] || { warn 'Scheduled backups require root.'; return 1; }; }
RUNNER_HELPERS
  for function_name in backup_all backup_lock backup_compose backup_wait_database \
    backup_validate_files backup_unpack_verified backup_prune backup_load_schedule \
    backup_archive_paths run_scheduled_backup; do
    declare -f "$function_name" || return 1
  done
  printf '\nneed_root || exit $?\nrun_scheduled_backup\n'
}

backup_write_schedule_units() {
  local calendar="$1" unit_dir="${2:-$(backup_schedule_unit_dir)}"
  printf '[Unit]\nDescription=Remnawave verified backup\n[Service]\nType=oneshot\nUMask=0077\nExecStart=/bin/bash %s/backup-runner.sh --scheduled-backup\n' "$STATE_DIR" > "$unit_dir/remnawave-installer-backup.service" || return 1
  printf '[Unit]\nDescription=Remnawave backup schedule\n[Timer]\nOnCalendar=%s\nPersistent=true\n[Install]\nWantedBy=timers.target\n' "$calendar" > "$unit_dir/remnawave-installer-backup.timer" || return 1
}

configure_backup_schedule() (
  local frequency time keep days calendar
  backup_load_schedule || return 1
  while true; do
    ask "Schedule: off, daily, weekly (0: back)" frequency "$BACKUP_FREQUENCY" || return $?
    [ "$frequency" != 0 ] || return 131
    [[ "$frequency" =~ ^(off|daily|weekly)$ ]] && break
    warn "Choose off, daily or weekly."
  done
  time="$BACKUP_TIME" keep="$BACKUP_KEEP" days="$BACKUP_DAYS"
  if [ "$frequency" != off ]; then
    while true; do
      ask "Time HH:MM, server local time" time "$time" || return $?
      [[ "$time" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] && break
      warn "Enter 00:00 through 23:59."
    done
    while true; do
      ask "Keep newest archives (0: unlimited)" keep "$keep" || return $?
      [[ "$keep" =~ ^(0|[1-9][0-9]{0,4})$ ]] && break
      warn "Enter an integer from 0 to 99999."
    done
    while true; do
      ask "Maximum age in days (0: unlimited)" days "$days" || return $?
      [[ "$days" =~ ^(0|[1-9][0-9]{0,4})$ ]] && break
      warn "Enter an integer from 0 to 99999."
    done
    # systemd paths are deliberately restricted to avoid unit directive injection.
    [[ "$STATE_DIR" =~ ^/[a-zA-Z0-9_./-]+$ ]] || return 1
  fi
  printf 'Schedule: %s at %s (%s); weekly: Monday. Keep: %s; age: %s days. Newest successful backup is always preserved.\n' "$frequency" "$time" "$(date +%Z)" "$keep" "$days"
  confirm "Apply this backup schedule?" || return $?
  command -v systemctl >/dev/null || { warn "systemd is required for scheduled backups."; return 1; }
  umask 077
  backup_lock || return 1
  mkdir -p "$STATE_DIR" || return 1
  chmod 700 "$STATE_DIR" || return 1
  local unit_dir snapshot prior_enabled prior_active prior_load file index=0 changed=0 committed=0
  unit_dir="$(backup_schedule_unit_dir)" || return 1
  backup_timer_state || { warn "Cannot determine the current timer state; schedule unchanged."; return 1; }
  prior_enabled="$BACKUP_TIMER_ENABLED" prior_active="$BACKUP_TIMER_ACTIVE" prior_load="$BACKUP_TIMER_LOAD"
  case "$prior_enabled" in enabled|disabled|absent) ;; *) warn "Timer has unsupported state $prior_enabled; schedule unchanged."; return 1 ;; esac
  local owned=("$STATE_DIR/backup-schedule.conf" "$STATE_DIR/backup-runner.sh"
    "$unit_dir/remnawave-installer-backup.service" "$unit_dir/remnawave-installer-backup.timer")
  snapshot="$(mktemp -d "$STATE_DIR/.backup-schedule.XXXXXX")" || return 1
  backup_schedule_cleanup() {
    local status="$?" rollback_ok=1 position=0 target
    trap - EXIT
    if [ "$changed" = 1 ] && [ "$committed" = 0 ]; then
      # Stop the new timer before restoring files; the shared lock excludes backups.
      if [ -f "$unit_dir/remnawave-installer-backup.timer" ] || [ "$prior_load" != not-found ]; then
        backup_schedule_systemctl disable --now remnawave-installer-backup.timer >/dev/null 2>&1 || rollback_ok=0
      fi
      for target in "${owned[@]}"; do
        if [ -f "$snapshot/$position" ]; then
          cp -p -- "$snapshot/$position" "$target" || rollback_ok=0
        else
          rm -f -- "$target" || rollback_ok=0
        fi
        position=$((position + 1))
      done
      backup_schedule_systemctl daemon-reload || rollback_ok=0
      if [ "$prior_enabled" = enabled ]; then
        backup_schedule_systemctl enable remnawave-installer-backup.timer || rollback_ok=0
      elif [ "$prior_load" != not-found ]; then
        backup_schedule_systemctl disable remnawave-installer-backup.timer || rollback_ok=0
      fi
      if [ "$prior_active" = active ]; then
        backup_schedule_systemctl start remnawave-installer-backup.timer || rollback_ok=0
      elif [ "$prior_load" != not-found ]; then
        backup_schedule_systemctl stop remnawave-installer-backup.timer || rollback_ok=0
      fi
      status=1
      if [ "$rollback_ok" = 1 ]; then
        warn "Backup schedule update failed; previous configuration and timer state restored."
      else
        warn "Backup schedule update failed; timer rollback needs attention. Saved previous files: $snapshot"
      fi
    fi
    rm -f -- "$STATE_DIR/backup-runner.sh.tmp" "$STATE_DIR/backup-schedule.conf.tmp"
    [ "$rollback_ok" != 1 ] || rm -rf -- "$snapshot"
    exit "$status"
  }
  trap backup_schedule_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  for file in "${owned[@]}"; do
    [ ! -L "$file" ] || { warn "Refusing linked schedule file: $file"; return 1; }
    if [ -e "$file" ]; then
      [ -f "$file" ] && cp -p -- "$file" "$snapshot/$index" || return 1
    fi
    index=$((index + 1))
  done
  changed=1
  if [ "$frequency" = off ]; then
    if [ "$prior_load" != not-found ]; then
      backup_schedule_systemctl disable --now remnawave-installer-backup.timer || return 1
    fi
  else
    backup_write_runner > "$STATE_DIR/backup-runner.sh.tmp" || return 1
    bash -n "$STATE_DIR/backup-runner.sh.tmp" || return 1
    chmod 700 "$STATE_DIR/backup-runner.sh.tmp" || return 1
    mv -- "$STATE_DIR/backup-runner.sh.tmp" "$STATE_DIR/backup-runner.sh" || return 1
    calendar="*-*-* $time:00"
    [ "$frequency" != weekly ] || calendar="Mon *-*-* $time:00"
    backup_write_schedule_units "$calendar" "$unit_dir" || return 1
    backup_schedule_systemctl daemon-reload || return 1
  fi
  printf 'frequency=%s\ntime=%s\nkeep=%s\ndays=%s\n' "$frequency" "$time" "$keep" "$days" > "$STATE_DIR/backup-schedule.conf.tmp" || return 1
  mv -- "$STATE_DIR/backup-schedule.conf.tmp" "$STATE_DIR/backup-schedule.conf" || return 1
  if [ "$frequency" != off ]; then
    backup_schedule_systemctl enable --now remnawave-installer-backup.timer || return 1
    backup_schedule_systemctl restart remnawave-installer-backup.timer || return 1
  fi
  committed=1
  show_backup_schedule
)

run_scheduled_backup() {
  local BACKUP_SCHEDULED_RUN=1
  backup_load_schedule || return 1
  [ "$BACKUP_FREQUENCY" != off ] || return 0
  backup_all
}

# BACKUP_RESTORE END

# PANEL_STATE BEGIN

save_panel_state() {
  local panel_domain="$1"
  local webserver="$2"
  local email="$3"
  local subscription_domain="${4:-}"

  mkdir -p "$STATE_DIR"
  
  chmod 700 "$STATE_DIR"
  
  local state_tmp
  state_tmp=$(umask 077; mktemp "${PANEL_STATE_FILE}.XXXXXX") || return 1
  cat > "$state_tmp" <<EOF
PANEL_DOMAIN=$(shell_quote "$panel_domain")
WEBSERVER=$(shell_quote "$webserver")
LETSENCRYPT_EMAIL=$(shell_quote "$email")
SUBSCRIPTION_DOMAIN=$(shell_quote "$subscription_domain")
EOF

  chmod 600 "$state_tmp" && mv -f -- "$state_tmp" "$PANEL_STATE_FILE"
}

save_panel_draft() {
  local PANEL_STATE_FILE="${PANEL_STATE_FILE}.draft"
  save_panel_state "$@"
}

load_panel_draft() {
  local PANEL_STATE_FILE="${PANEL_STATE_FILE}.draft"
  load_panel_state
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

    run_cmd "Ensure Caddy service is enabled" systemctl enable --now caddy || return 1

    return 0
  fi

  section "Caddy"

  run_cmd_stream "Install Caddy repository prerequisites" apt-get install -y debian-keyring debian-archive-keyring || return 1

  run_cmd_stream "Install Caddy apt repository key" bash -c "curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --yes --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg" || return 1
  run_cmd "Install Caddy apt source list" bash -c "curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list" || return 1

  run_cmd_stream "Update apt package index for Caddy" apt-get update || return 1

  run_cmd_stream "Install Caddy" apt-get install -y caddy || return 1
  
  run_cmd "Enable and start Caddy" systemctl enable --now caddy || return 1
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

  local caddyfile="${PANEL_CADDY_FILE:-/etc/caddy/Caddyfile}"

  local tmp_file

  install_caddy || return 1

  mkdir -p /etc/caddy /var/log/caddy || return 1
  chown -R caddy:caddy /var/log/caddy || true
  touch /var/log/caddy/remnawave-panel.access.log || return 1
  chown caddy:caddy /var/log/caddy/remnawave-panel.access.log || true
  chmod 640 /var/log/caddy/remnawave-panel.access.log || true

  [ -f "$caddyfile" ] || touch "$caddyfile" || return 1

  cp "$caddyfile" "${caddyfile}.bak.$(date +%Y%m%d%H%M%S)" || return 1



  tmp_file="$(mktemp "${caddyfile}.stage.XXXXXX")" || return 1

  awk '
    /^# BEGIN REMNAWAVE PANEL$/ { skip=1; next }
    /^# END REMNAWAVE PANEL$/ { skip=0; next }
    skip != 1 { print }
  ' "$caddyfile" > "$tmp_file" || { rm -f "$tmp_file"; return 1; }

  {
    printf "\n# BEGIN REMNAWAVE PANEL\n" || { rm -f "$tmp_file"; return 1; }
    printf "%s {\n" "$panel_domain" || { rm -f "$tmp_file"; return 1; }
    if [ -n "$email" ]; then printf "\ttls %s\n" "$email" || { rm -f "$tmp_file"; return 1; }; fi
    printf "\tencode zstd gzip\n" || { rm -f "$tmp_file"; return 1; }
    printf "\tlog {\n" || { rm -f "$tmp_file"; return 1; }
    printf "\t\toutput file /var/log/caddy/remnawave-panel.access.log {\n" || { rm -f "$tmp_file"; return 1; }
    printf "\t\t\troll_size 100MiB\n" || { rm -f "$tmp_file"; return 1; }
    printf "\t\t\troll_keep 10\n" || { rm -f "$tmp_file"; return 1; }
    printf "\t\t\troll_keep_for 720h\n" || { rm -f "$tmp_file"; return 1; }
    printf "\t\t}\n" || { rm -f "$tmp_file"; return 1; }
    printf "\t\tformat json\n" || { rm -f "$tmp_file"; return 1; }
    printf "\t}\n" || { rm -f "$tmp_file"; return 1; }
    printf "\theader {\n" || { rm -f "$tmp_file"; return 1; }
    printf "\t\tStrict-Transport-Security \"max-age=31536000; includeSubDomains\"\n" || { rm -f "$tmp_file"; return 1; }
    printf "\t\tX-Content-Type-Options \"nosniff\"\n" || { rm -f "$tmp_file"; return 1; }
    printf "\t\tX-Frame-Options \"SAMEORIGIN\"\n" || { rm -f "$tmp_file"; return 1; }
    printf "\t\tReferrer-Policy \"strict-origin-when-cross-origin\"\n" || { rm -f "$tmp_file"; return 1; }
    printf "\t}\n" || { rm -f "$tmp_file"; return 1; }
    printf "\treverse_proxy 127.0.0.1:3000\n" || { rm -f "$tmp_file"; return 1; }
    printf "}\n" || { rm -f "$tmp_file"; return 1; }
    printf "# END REMNAWAVE PANEL\n" || { rm -f "$tmp_file"; return 1; }
  } >> "$tmp_file" || { rm -f "$tmp_file"; return 1; }

  run_cmd_stream "Validate staged Caddy configuration" caddy validate --adapter caddyfile --config "$tmp_file" || { rm -f "$tmp_file"; return 1; }
  install -o root -g caddy -m 640 "$tmp_file" "$caddyfile" || return 1

  rm -f "$tmp_file"

  run_cmd_stream "Validate Caddy configuration" caddy validate --config "$caddyfile" || return 1

  run_cmd "Reload Caddy" systemctl reload caddy || return 1

  ok "Caddy configured for ${panel_domain}. Certificate issuance will be handled automatically by Caddy."
}

install_nginx() {
  if command_exists nginx; then
    ok "NGINX is already installed."

    run_cmd_stream "Install Certbot NGINX plugin" apt-get install -y certbot python3-certbot-nginx || return 1

    run_cmd "Ensure NGINX service is enabled" systemctl enable --now nginx || return 1
  else
    section "NGINX"

    run_cmd_stream "Install NGINX apt repository key" bash -c 'curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --yes --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg' || return 1
    
    echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/ubuntu $(lsb_release -cs) nginx" > /etc/apt/sources.list.d/nginx.list
    
    printf '%s\n' \
      'Package: *' \
      'Pin: origin nginx.org' \
      'Pin: release o=nginx' \
      'Pin-Priority: 900' > /etc/apt/preferences.d/99nginx
    
    run_cmd_stream "Update apt package index for NGINX" apt-get update || return 1

    run_cmd_stream "Install NGINX and Certbot" apt-get install -y nginx certbot python3-certbot-nginx || return 1

    run_cmd "Enable and start NGINX" systemctl enable --now nginx || return 1
  fi
}

configure_nginx_panel() {
  local panel_domain="$1"
  local email="$2"

  local conf="${PANEL_NGINX_FILE:-/etc/nginx/conf.d/remnawave-panel.conf}"

  local certbot_args=()
  local stage_conf

  install_nginx || return 1

  if [ -f "$conf" ]; then
    cp "$conf" "${conf}.bak.$(date +%Y%m%d%H%M%S)" || return 1
  fi

  stage_conf=$(mktemp "${conf}.stage.XXXXXX") || return 1
  cat > "$stage_conf" <<EOF
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

  local write_status=$?
  [ "$write_status" = 0 ] || { rm -f "$stage_conf"; return "$write_status"; }
  chmod 644 "$stage_conf" && mv -f "$stage_conf" "$conf" || { rm -f "$stage_conf"; return 1; }
  run_cmd_stream "Validate NGINX configuration" nginx -t || return 1

  run_cmd "Reload NGINX" systemctl reload nginx || return 1

  if [ -n "$email" ]; then
    certbot_args+=(--email "$email")
  else
    certbot_args+=(--register-unsafely-without-email)
  fi

  run_cmd_stream "Issue TLS certificate with Certbot" certbot --nginx -d "$panel_domain" "${certbot_args[@]}" --agree-tos --non-interactive --redirect || return 1

  setup_certbot_auto_renew "nginx" || warn "Certbot auto-renew setup reported an error."

  run_cmd_stream "Validate NGINX configuration after Certbot" nginx -t || return 1

  run_cmd "Reload NGINX after Certbot" systemctl reload nginx || return 1

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

  ask_validated "Email Let's Encrypt" email validate_email "Enter an email such as admin@example.com." || return $?

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

  ask_validated "Email Let's Encrypt" email validate_email "Enter an email such as admin@example.com." || return $?

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
  local input_status mode username="" password response access_token response_file http_code register_allowed
  PANEL_ADMIN_USERNAME=""
  PANEL_ADMIN_PASSWORD=""

  if [ -z "$panel_base" ]; then
    panel_base="$(default_panel_api_base)"
  fi

  if ! response=$(curl -fsS --connect-timeout 5 --max-time 30 -H "X-Forwarded-Proto: https" -H "X-Forwarded-For: 127.0.0.1" "${panel_base%/}/api/auth/status"); then
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
    ask_choice "Selection" mode 0 2 "1" || return $?

    case "$mode" in
      1)
        while true; do
          input_status=0
          ask_required "Admin username" username "$username" || input_status=$?
          case "$input_status" in 131) continue 2 ;; 0) ;; *) return "$input_status" ;; esac
          info "Admin password requires at least 24 characters, including uppercase and lowercase letters and numbers."
          while true; do
            input_status=0
            ask_secret_required "Admin password" password || input_status=$?
            case "$input_status" in 131) continue 2 ;; 0) ;; *) return "$input_status" ;; esac
            if validate_admin_password "$password"; then break 2; fi
            warn "Password must be at least 24 characters and include uppercase and lowercase letters and numbers. Please try again."
          done
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
    http_code=$(curl -sS --connect-timeout 5 --max-time 30 -o "$response_file" -w "%{http_code}" -X POST "${panel_base%/}/api/auth/register" \
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

  if [ "$webserver" = none ]; then
    summary_item "Local URL" "http://127.0.0.1:3000"
  else
    summary_item "URL" "https://${panel_domain}"
  fi

  if [ -n "$subscription_domain" ]; then
    summary_item "Subscription URL" "https://${subscription_domain}"
  fi

  summary_item "Directory" "${PANEL_DIR}"
  summary_item "ENV" "${PANEL_DIR}/.env"
  summary_item "Compose" "${PANEL_DIR}/docker-compose.yml"
  summary_item "Reverse proxy" "${webserver}"

  if [ -n "$PANEL_ADMIN_USERNAME" ] && [ -n "$PANEL_ADMIN_PASSWORD" ]; then
    printf '    Admin username: %s\n    Admin password: %s\n' "$PANEL_ADMIN_USERNAME" "$PANEL_ADMIN_PASSWORD"
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

# Collect all choices before installing packages or downloading files. Drafts contain no secrets.
panel_setup_preferences() {
  local include_subscription="${1:-yes}" step=1 rc choice=1
  load_panel_state
  load_panel_draft
  PANEL_DOMAIN="${PANEL_DOMAIN:-}"
  SUBSCRIPTION_DOMAIN="${SUBSCRIPTION_DOMAIN:-}"
  LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-}"
  WEBSERVER="${WEBSERVER:-caddy}"
  while [ "$step" -le 4 ]; do
    rc=0
    case "$step" in
      1) ask_validated "Panel domain" PANEL_DOMAIN validate_domain "Enter a domain without https:// or a path." "$PANEL_DOMAIN" || rc=$? ;;
      2)
        if [ "$include_subscription" = no ]; then step=3; continue; fi
        ask_validated "Subscription page domain" SUBSCRIPTION_DOMAIN validate_domain "Enter a valid domain." "${SUBSCRIPTION_DOMAIN:-$(default_subscription_domain "$PANEL_DOMAIN")}" || rc=$?
        if [ "$rc" = 0 ] && [ "$SUBSCRIPTION_DOMAIN" = "$PANEL_DOMAIN" ]; then warn "Choose different Panel and subscription domains."; continue; fi
        ;;
      3) ask_validated "Certificate email (optional)" LETSENCRYPT_EMAIL validate_optional_email "Enter a valid email address or leave empty." "$LETSENCRYPT_EMAIL" || rc=$? ;;
      4)
        case "$WEBSERVER" in caddy) choice=1;; nginx) choice=2;; none) choice=3;; esac
        menu_item 1 "Caddy, automatic HTTPS"
        menu_item 2 "NGINX + Certbot"
        menu_item 3 "Local access only"
        ask_choice "Reverse proxy" choice 1 3 "$choice" || rc=$?
        if [ "$rc" = 0 ]; then case "$choice" in 1) WEBSERVER=caddy;; 2) WEBSERVER=nginx;; 3) WEBSERVER=none;; esac; fi
        ;;
    esac
    case "$rc" in
      0) save_panel_draft "$PANEL_DOMAIN" "$WEBSERVER" "$LETSENCRYPT_EMAIL" "$SUBSCRIPTION_DOMAIN" || return 1; step=$((step+1));;
      131) if [ "$step" -gt 1 ]; then step=$((step-1)); [ "$include_subscription:$step" != no:2 ] || step=1; else return 131; fi;;
      *) return "$rc";;
    esac
  done
}

panel_proxy_path() {
  case "$1" in
    caddy) printf '%s' "${PANEL_CADDY_FILE:-/etc/caddy/Caddyfile}";;
    nginx) printf '%s' "${PANEL_NGINX_FILE:-/etc/nginx/conf.d/remnawave-panel.conf}";;
  esac
}

# Never switch a live proxy implicitly: its other sites may depend on it.
check_panel_proxy_choice() {
  local selected="$1" other
  if [ "$selected" = none ] && { grep -Fq '# BEGIN REMNAWAVE PANEL' "$(panel_proxy_path caddy)" 2>/dev/null || [ -s "$(panel_proxy_path nginx)" ]; }; then
    warn "Existing proxy configuration must be removed or migrated manually before choosing local access only."
    return 1
  fi
  case "$selected" in caddy) other=nginx;; nginx) other=caddy;; none) return 0;; *) return 1;; esac
  if systemctl is-active --quiet "$other" || [ -s "$(panel_proxy_path "$other")" ]; then
    warn "${other} already has configuration or is running. Keep that proxy, or migrate it manually before selecting ${selected}."
    return 1
  fi
}

# Snapshot only the owned proxy file; retain a protected backup after failure.
apply_panel_https() (
  local domain="$1" proxy="$2" email="$3" subscription="$4"
  local stage proxy_file old_proxy=0 committed=0 env_changed=0 state_file key
  check_panel_proxy_choice "$proxy" || return 1
  stage=$(umask 077; mktemp -d "$PANEL_DIR/.https-backup.XXXXXX") || return 1
  cp -p "$PANEL_DIR/.env" "$stage/env" || return 1
  for key in panel auth; do
    state_file="$PANEL_STATE_FILE"
    [ "$key" != auth ] || state_file="$PANEL_AUTH_STATE_FILE"
    [ ! -f "$state_file" ] || cp -p "$state_file" "$stage/$key" || return 1
  done
  proxy_file=$(panel_proxy_path "$proxy")
  if [ -n "$proxy_file" ] && [ -f "$proxy_file" ]; then
    cp -p "$proxy_file" "$stage/proxy" || return 1
    old_proxy=1
  fi
  rollback_panel_https() {
    local status=$? rollback_ok=1
    local OPERATION_ACTIVE=0
    if [ "$committed" = 0 ]; then
      cp -p "$stage/env" "$PANEL_DIR/.env" || rollback_ok=0
      for key in panel auth; do
        state_file="$PANEL_STATE_FILE"
        [ "$key" != auth ] || state_file="$PANEL_AUTH_STATE_FILE"
        if [ -f "$stage/$key" ]; then cp -p "$stage/$key" "$state_file" || rollback_ok=0; else rm -f -- "$state_file" || rollback_ok=0; fi
      done
      if [ -n "$proxy_file" ]; then
        if [ "$old_proxy" = 1 ]; then cp -p "$stage/proxy" "$proxy_file" || rollback_ok=0; else rm -f -- "$proxy_file" || rollback_ok=0; fi
        systemctl reload "$proxy" >/dev/null 2>&1 || rollback_ok=0
      fi
      if [ "$env_changed" = 1 ]; then start_panel_stack >/dev/null 2>&1 || rollback_ok=0; fi
      if [ "$rollback_ok" = 1 ]; then
        warn "HTTPS changes rolled back. Backup: ${stage}. Correct the draft and retry Panel HTTPS setup."
      else
        warn "HTTPS setup failed and rollback needs attention. Previous files: ${stage}. Check Panel -> Logs and the proxy before continuing."
      fi
    fi
    exit "$status"
  }
  trap rollback_panel_https EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  cp -p "$stage/env" "$stage/env.new" || return 1
  set_env_value "$stage/env.new" FRONT_END_DOMAIN "$domain" || return 1
  set_env_value "$stage/env.new" PANEL_DOMAIN "$domain" || return 1
  mv -f "$stage/env.new" "$PANEL_DIR/.env" || return 1
  env_changed=1
  start_panel_stack || return 1
  configure_panel_reverse_proxy "$domain" "$proxy" "$email" || return 1
  operation_set_step 'Verify public Panel access' 'Panel -> Configure domain / HTTPS can repair DNS, certificate and proxy settings.'
  check_panel_url "$domain" "$proxy" || return 1
  save_panel_state "$domain" "$proxy" "$email" "$subscription" || return 1
  local base="https://${domain}"
  [ "$proxy" != none ] || base=http://127.0.0.1:3000
  remember_panel_auth "$base" || return 1
  committed=1
  rm -f -- "${PANEL_STATE_FILE}.draft"
)

reconfigure_panel_https() {
  validate_panel_v3 || return 1
  panel_setup_preferences no || return $?
  check_domain_dns "$PANEL_DOMAIN" || return $?
  apply_panel_https "$PANEL_DOMAIN" "$WEBSERVER" "$LETSENCRYPT_EMAIL" "$SUBSCRIPTION_DOMAIN" || return $?
  print_panel_summary "$PANEL_DOMAIN" "$WEBSERVER" "$SUBSCRIPTION_DOMAIN"
}

resume_panel_setup() {
  local status register_allowed base
  load_panel_state
  if [ ! -e "$PANEL_DIR/.env" ] && [ ! -L "$PANEL_DIR/.env" ] &&
    [ ! -e "$PANEL_DIR/docker-compose.yml" ] && [ ! -L "$PANEL_DIR/docker-compose.yml" ]; then
    install_panel
    return $?
  fi
  if [ ! -f "$PANEL_DIR/.env" ] || [ -L "$PANEL_DIR/.env" ] ||
    [ ! -f "$PANEL_DIR/docker-compose.yml" ] || [ -L "$PANEL_DIR/docker-compose.yml" ]; then
    warn "Panel configuration is incomplete. Restore the missing original file from backup; existing secrets were preserved."
    return 1
  fi
  validate_panel_v3 || return 1
  # Inspect reality, not a saved completed flag.
  if ! check_panel_url "${PANEL_DOMAIN:-}" none 1 0; then
    start_panel_stack || return 1
  fi
  if [ -z "${PANEL_DOMAIN:-}" ] || [ -z "${WEBSERVER:-}" ]; then
    reconfigure_panel_https || return $?
    load_panel_state
  elif ! check_panel_url "$PANEL_DOMAIN" "$WEBSERVER" 1 0; then
    note "Panel backend responds, but public access needs repair."
    reconfigure_panel_https || return $?
    load_panel_state
  fi
  base="https://${PANEL_DOMAIN}"
  [ "$WEBSERVER" != none ] || base=http://127.0.0.1:3000
  status=$(curl -fsS --connect-timeout 5 --max-time 15 -H 'X-Forwarded-Proto: https' -H 'X-Forwarded-For: 127.0.0.1' "${base}/api/auth/status") || return 1
  register_allowed=$(printf '%s' "$status" | jq -r '.response.isRegisterAllowed | if type == "boolean" then tostring else empty end') || return 1
  case "$register_allowed" in
    true) if confirm "Create the missing Panel admin now?"; then create_panel_admin "$base" || return $?; fi;;
    false) ok "Panel admin already exists.";;
    *) warn "Cannot determine administrator registration state."; return 1;;
  esac
  if [ ! -f "$PANEL_DIR/docker-compose.subscription.yml" ]; then
    if confirm "Configure the missing subscription page now?"; then setup_subscription_page_for_panel "${SUBSCRIPTION_DOMAIN:-}" || return $?; fi
  else
    if ! check_subscription_page_url "${SUBSCRIPTION_DOMAIN:-}" "$WEBSERVER" 1 0; then
      warn "Subscription configuration exists but its endpoint is not ready. Use Panel -> Start and Panel -> Logs to investigate; its API token was preserved."
      return 1
    fi
    note "Existing subscription page responds; keeping its configuration and API token."
  fi
  check_panel_url "$PANEL_DOMAIN" "$WEBSERVER" || return 1
  print_panel_summary "$PANEL_DOMAIN" "$WEBSERVER" "${SUBSCRIPTION_DOMAIN:-}"
}

install_panel() {
  section "Install or continue Remnawave Panel"
  if [ -e "$PANEL_DIR/.env" ] || [ -L "$PANEL_DIR/.env" ] || [ -e "$PANEL_DIR/docker-compose.yml" ] || [ -L "$PANEL_DIR/docker-compose.yml" ]; then
    resume_panel_setup
    return $?
  fi
  panel_setup_preferences || return $?
  install_prerequisites || return $?
  check_domain_dns "$PANEL_DOMAIN" || return $?
  check_domain_dns "$SUBSCRIPTION_DOMAIN" || return $?
  prepare_new_panel_files "$PANEL_DOMAIN" "$SUBSCRIPTION_DOMAIN" || return $?
  # Save choices before startup/HTTPS can fail, enabling continuation after interruption.
  save_panel_state "$PANEL_DOMAIN" "$WEBSERVER" "$LETSENCRYPT_EMAIL" "$SUBSCRIPTION_DOMAIN" || return 1
  apply_panel_https "$PANEL_DOMAIN" "$WEBSERVER" "$LETSENCRYPT_EMAIL" "$SUBSCRIPTION_DOMAIN" || return $?
  resume_panel_setup
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

  http_code=$(curl -sS --connect-timeout 5 --max-time 30 -o "$response_file" -w "%{http_code}" -X GET "${panel_base%/}/api/config-profiles" \
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
  http_code=$(curl -sS --connect-timeout 5 --max-time 30 -o "$response_file" -w "%{http_code}" -X POST "${panel_base%/}/api/auth/login" \
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
  local OPERATION_ACTIVE=0
  local api_token="" username="" password="" auth_choice answer_status
  local default_username=""

  load_panel_auth_state
  if [ -n "${PANEL_AUTH_TOKEN:-}" ]; then
    answer_status=0
    confirm "Use previously saved Panel API/access token for ${panel_base}?" || answer_status=$?
    [ "$answer_status" -lt 130 ] || return "$answer_status"
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
    [ "$answer_status" -lt 130 ] || return "$answer_status"
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
    menu_item 0 "Back to Panel URL"
    blank
    ask_choice "Selection" auth_choice 0 2 "1" || return $?
    case "$auth_choice" in
      0) return 131 ;;
      1)
        ask_secret_required "Panel API/access token" api_token || return $?
        ;;
      2)
        ask_required "Panel username" username "$default_username" || return $?
        default_username="$username"
        ask_secret_required "Panel password" password || return $?
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

ask_panel_auth() {
  local __panel_auth_base="${3:-}" __panel_auth_token="" __panel_auth_status=0
  while true; do
    ask_validated "Panel URL" __panel_auth_base validate_url "Enter an HTTP(S) URL without credentials, query or fragment." "$__panel_auth_base" || return $?
    __panel_auth_base="${__panel_auth_base%/}"
    __panel_auth_status=0
    get_panel_api_token "$__panel_auth_base" __panel_auth_token || __panel_auth_status=$?
    case "$__panel_auth_status" in
      0)
        printf -v "$1" '%s' "$__panel_auth_base"
        printf -v "$2" '%s' "$__panel_auth_token"
        return 0 ;;
      131) continue ;;
      *) return "$__panel_auth_status" ;;
    esac
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

  ask_panel_auth panel_base token "$default_panel_base" || return $?

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
      ask_validated "Email for Let's Encrypt/Caddy (can be empty)" letsencrypt_email validate_optional_email "Enter a valid email or leave it empty." || return $?
    fi
  fi

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

    ask_panel_auth panel_base token "$default_panel_base" || return $?

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

  ask_delete_confirmation answer || return $?

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

# DIAGNOSTICS BEGIN

# Only allowlisted facts enter reports. Never collect environment, raw logs, or
# unrestricted inspect output. All subprocess probes have a deadline.
diagnostic_run() {
  command -v timeout >/dev/null 2>&1 || return 1
  timeout 3 "$@" 2>/dev/null
}

diagnostic_domain() {
  local value="${1:-}"
  if [[ "$value" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]] && [[ "$value" == *.* ]] && [ "${#value}" -le 253 ]; then
    printf '%s' "$value"
  fi
}

diagnostic_snapshot() {
  DIAG_DOCKER=unknown
  DIAG_CONTAINERS=""
  if ! command -v docker >/dev/null 2>&1; then DIAG_DOCKER=unavailable; return 0; fi
  # A successful list distinguishes absent containers from an unreachable daemon.
  if DIAG_CONTAINERS="$(diagnostic_run docker ps -a --format '{{.Names}}|{{.State}}|{{.Status}}|{{.Image}}')"; then
    DIAG_DOCKER=available
  fi
}

diagnostic_container() {
  local wanted="$1" name state health image
  if [ "$DIAG_DOCKER" != available ]; then printf 'unknown (Docker %s)' "$DIAG_DOCKER"; return; fi
  while IFS='|' read -r name state health image; do
    [ "$name" = "$wanted" ] || continue
    case "$state" in
      running)
        case "$health" in
          *'(unhealthy)'*) printf 'running / unhealthy' ;;
          *'(healthy)'*) printf 'running / healthy' ;;
          *'(health: starting)'*) printf 'running / health starting' ;;
          *) printf 'running / health not reported' ;;
        esac ;;
      exited|dead|created|paused|restarting|removing) printf '%s' "$state" ;;
      *) printf 'unknown' ;;
    esac
    return
  done <<< "$DIAG_CONTAINERS"
  printf 'absent'
}

diagnostic_image() {
  local name state health image
  while IFS='|' read -r name state health image; do
    [ "$name" = remnawave ] || continue
    if [[ "$image" =~ ^(ghcr.io/)?remnawave/backend:[a-zA-Z0-9._-]+$ ]]; then
      printf '%s (image tag; exact runtime version not verified)' "${image##*:}"
      return
    fi
  done <<< "$DIAG_CONTAINERS"
  printf 'unknown'
}

diagnostic_certificate() {
  local domain="$1" file expiry candidate
  [ -n "$domain" ] || { printf 'unknown (no domain)'; return; }
  file="/etc/letsencrypt/live/${domain}/fullchain.pem"
  if [ ! -r "$file" ]; then
    for candidate in /var/lib/caddy/.local/share/caddy/certificates/*/"$domain"/"$domain.crt"; do
      [ -r "$candidate" ] || continue
      file="$candidate"
      break
    done
  fi
  if [ -r "$file" ] && command -v openssl >/dev/null 2>&1; then
    expiry="$(diagnostic_run openssl x509 -in "$file" -noout -enddate || true)"
    if [[ "$expiry" =~ ^notAfter=([A-Za-z]{3}[[:space:]]+[0-9]{1,2}[[:space:]][0-9:]{8}[[:space:]][0-9]{4}[[:space:]]GMT)$ ]]; then
      printf '%s' "${BASH_REMATCH[1]}"
      if ! diagnostic_run openssl x509 -in "$file" -noout -checkend 604800 >/dev/null; then
        printf ' (expired or expires within 7 days; check renewal)'
      fi
      return
    fi
  fi
  printf 'unknown (local certificate unavailable; use diagnostics for HTTPS)'
}

diagnostic_latest_backup() {
  local record="$STATE_DIR/last-backup.status" key value status='' timestamp='' archive='' latest='' candidate
  if [ -f "$record" ] && [ ! -L "$record" ]; then
    while IFS='=' read -r key value; do
      case "$key" in status) status="$value";; timestamp) timestamp="$value";; archive) archive="$value";; esac
    done < "$record"
    if [ "$status" = success ] && [[ "$timestamp" =~ ^[0-9]{1,12}$ ]] &&
      [ "${archive%/*}" = "$BACKUP_ROOT" ] && [[ "${archive##*/}" =~ ^remnawave-backup-[a-zA-Z0-9.-]+\.tar\.gz$ ]]; then
      if [ -f "$archive" ] && [ ! -L "$archive" ]; then
        printf '%s (verified when created)' "$(date -d "@$timestamp" '+%Y-%m-%d %H:%M %Z' 2>/dev/null || printf 'recorded success')"
      else
        printf 'last successful archive is missing; create a new backup'
      fi
      return
    fi
  fi
  for candidate in "$BACKUP_ROOT"/remnawave-backup-*.tar.gz; do
    [ -f "$candidate" ] && [ ! -L "$candidate" ] || continue
    [[ "${candidate##*/}" =~ ^remnawave-backup-[a-zA-Z0-9.-]+\.tar\.gz$ ]] || continue
    if [ -z "$latest" ] || [ "$candidate" -nt "$latest" ]; then latest="$candidate"; fi
  done
  if [ -n "$latest" ]; then
    printf '%s (verification not recorded; use Verify backup)' "${latest##*/}"
  else
    printf 'none'
  fi
}

show_dashboard() (
  load_panel_state
  local domain address='' index state label color name panel_state
  local names=(remnawave remnawave-subscription-page remnanode)
  local labels=(Panel Subscription Node)
  local configs=("$PANEL_DIR/docker-compose.yml" "$PANEL_DIR/docker-compose.subscription.yml" "$NODE_DIR/docker-compose.yml")
  local issues=()
  domain="$(diagnostic_domain "${PANEL_DOMAIN:-}")"
  if [ "${WEBSERVER:-}" = none ]; then address='http://127.0.0.1:3000 (local)'
  elif [ -n "$domain" ]; then address="https://$domain"; fi
  diagnostic_snapshot
  panel_state="$(diagnostic_container remnawave)"
  printf '\n'
  for index in "${!names[@]}"; do
    state="$(diagnostic_container "${names[index]}")"
    case "$state" in
      'running / healthy') label=Healthy; color="$GREEN" ;;
      'running / unhealthy'|dead) label=Unhealthy; color="$RED" ;;
      'running / health starting') label=Starting; color="$YELLOW" ;;
      restarting) label=Restarting; color="$YELLOW" ;;
      running*) label=Running; color="$CYAN" ;;
      exited|created) label=Stopped; color="$YELLOW" ;;
      removing) label=Removing; color="$YELLOW" ;;
      paused) label=Paused; color="$YELLOW" ;;
      absent)
        if [ -f "${configs[index]}" ]; then label='Not started'; color="$YELLOW"
        else label='Not installed'; color="$GRAY"; fi ;;
      *) label=Unknown; color="$GRAY" ;;
    esac
    if [ "$index" = 0 ] && [ -n "$address" ]; then
      printf '  %-14s %b%-14s%b%s\n' "${labels[index]}" "$color" "$label" "$RESET" "$address"
    else
      printf '  %-14s %b%s%b\n' "${labels[index]}" "$color" "$label" "$RESET"
    fi
  done
  if [ "$DIAG_DOCKER" != available ]; then
    issues+=('Docker unavailable')
  elif [ "$panel_state" != absent ] || [ -f "${configs[0]}" ]; then
    for name in remnawave-db remnawave-redis; do
      state="$(diagnostic_container "$name")"
      case "$state" in 'running / healthy'|'running / health not reported') continue ;; esac
      label=Database; [ "$name" != remnawave-redis ] || label=Redis
      issues+=("$label needs attention")
    done
  fi
  if [ "${#issues[@]}" -gt 0 ]; then
    printf '  %b! %s' "$YELLOW" "${issues[0]}"
    for ((index=1; index<${#issues[@]}; index++)); do printf '; %s' "${issues[index]}"; done
    printf '  [9] Diagnose%b\n' "$RESET"
  fi
  printf '\n'
)

show_status_details() (
  load_panel_state
  local domain name
  domain="$(diagnostic_domain "${PANEL_DOMAIN:-}")"
  diagnostic_snapshot
  if [ "${WEBSERVER:-}" = none ]; then
    printf '\nPanel: http://127.0.0.1:3000 (local access)\n'
  else
    printf '\nPanel: %s\n' "${domain:+https://$domain}"
    [ -n "$domain" ] || printf 'Panel URL not configured.\n'
  fi
  printf 'Installed backend: %s\n' "$(diagnostic_image)"
  for name in remnawave remnawave-db remnawave-redis remnawave-subscription-page remnanode; do
    printf '  %s: %s\n' "$name" "$(diagnostic_container "$name")"
  done
  if [ "${WEBSERVER:-}" != none ]; then printf 'Certificate expiry: %s\n' "$(diagnostic_certificate "$domain")"; fi
  printf 'Latest backup: %s\n' "$(diagnostic_latest_backup)"
)

diagnostic_http() {
  local status
  if ! command -v curl >/dev/null 2>&1; then printf 'unknown'; return; fi
  if ! status="$(diagnostic_run curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 2 --max-time 2 "$@")"; then status=000; fi
  [[ "$status" =~ ^[0-9]{3}$ ]] || status=000
  printf '%s' "$status"
}

diagnose_installation() (
  load_panel_state
  local domain subscription local_status public_status name state dns disk listeners port listeners_known=0 disk_path
  domain="$(diagnostic_domain "${PANEL_DOMAIN:-}")"
  subscription="$(diagnostic_domain "${SUBSCRIPTION_DOMAIN:-}")"
  printf 'Read-only diagnostics (HTTP 000 = connection/TLS failure; unknown = unavailable probe)\n'
  show_status_details
  diagnostic_snapshot
  for name in remnawave remnawave-db remnawave-redis remnawave-subscription-page; do
    state="$(diagnostic_container "$name")"
    case "$state" in
      absent) printf 'Hint: %s is absent; check whether that component was installed.\n' "$name" ;;
      exited|dead|paused|created|*unhealthy*) printf 'Hint: %s needs attention; inspect its service logs and configuration.\n' "$name" ;;
    esac
  done
  local_status="$(diagnostic_http -H 'X-Forwarded-Proto: https' -H 'X-Forwarded-For: 127.0.0.1' http://127.0.0.1:3000/api/auth/status)"
  printf 'Local backend API HTTP: %s\n' "$local_status"
  if [ -n "$domain" ] && [ "${WEBSERVER:-}" != none ]; then
    dns="$(diagnostic_run getent ahostsv4 "$domain" | awk '{print $1}' | sort -u || true)"
    if [ -n "$dns" ]; then
      printf 'Panel DNS IPv4:'
      while read -r state; do [[ "$state" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && printf ' %s' "$state"; done <<< "$dns"
      printf '\nCompare these addresses with the server public IP or intended CDN/proxy.\n'
    else printf 'Panel DNS: unresolved or lookup unavailable; check the A/AAAA records.\n'; fi
    public_status="$(diagnostic_http "https://${domain}/api/auth/status")"
    printf 'Public backend HTTPS (certificate verification enabled): %s\n' "$public_status"
    if [[ "$local_status" =~ ^2[0-9]{2}$ ]] && ! [[ "$public_status" =~ ^2[0-9]{2}$ ]]; then
      printf 'Hint: local API works but public API does not; check DNS, reverse proxy, certificate and ports 80/443.\n'
    fi
  fi
  if [[ "$(diagnostic_container remnawave-db)" == running* ]]; then
    if diagnostic_run docker exec remnawave-db pg_isready -q >/dev/null; then
      printf 'Database: accepting connections (authentication not tested)\n'
    else printf 'Database readiness: failed or probe unavailable; inspect database service logs.\n'; fi
  fi
  if [[ "$(diagnostic_container remnawave-subscription-page)" == running* ]]; then
    if diagnostic_run docker exec remnawave-subscription-page curl -fsS --max-time 2 -o /dev/null http://127.0.0.1:3010/internal/health >/dev/null; then
      printf 'Subscription internal health: passed\n'
    else printf 'Subscription internal health: failed or probe unavailable\n'; fi
  fi
  if [ -n "$subscription" ] && [ "${WEBSERVER:-}" != none ]; then
    printf 'Subscription public HTTPS root (not an end-to-end subscription test): %s\n' "$(diagnostic_http "https://${subscription}/")"
  fi
  if listeners="$(diagnostic_run ss -H -ltn)"; then listeners_known=1; fi
  for port in 80 443 3000; do
    if [ "$listeners_known" = 0 ]; then state=unknown
    elif awk -v p=":$port" '$4 ~ (p "$") {found=1} END {exit !found}' <<< "$listeners"; then state=listening
    else state='not listening'; fi
    printf 'TCP port %s: %s (external firewall not tested)\n' "$port" "$state"
  done
  disk_path="$PANEL_DIR"
  while [ ! -d "$disk_path" ] && [ "$disk_path" != / ]; do disk_path="$(dirname "$disk_path")"; done
  disk="$(diagnostic_run df -Pk "$disk_path" 2>/dev/null | awk 'NR==2 {print $5}' || true)"
  if [[ "$disk" =~ ^[0-9]+%$ ]]; then
    printf 'Panel filesystem used: %s\n' "$disk"
    if [ "${disk%%%}" -ge 90 ]; then printf 'Hint: free disk space before updating or backing up.\n'; fi
  else printf 'Panel filesystem used: unknown\n'; fi
)

export_diagnostic_report() (
  local report
  umask 077
  mkdir -p "${STATE_DIR}/reports" || return 1
  chmod 700 "${STATE_DIR}/reports" || return 1
  report="$(mktemp "${STATE_DIR}/reports/diagnostics-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX.txt")" || return 1
  chmod 600 "$report" || return 1
  if ! diagnose_installation > "$report"; then
    printf 'Diagnostic collection incomplete.\n' >> "$report"
  fi
  if declare -F operation_report_last >/dev/null; then operation_report_last >> "$report"; fi
  printf 'Diagnostic report saved: %s\n' "$report"
)

# DIAGNOSTICS END

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

  ask_panel_auth panel_base token "$default_panel_base" || return $?

  if ! ip link show warp >/dev/null 2>&1; then
    warn "Interface 'warp' is not available right now."
    note "The profile rule uses sockopt interface 'warp'; traffic will fail until WARP native is connected on the node."
    confirm "Add WARP rule to the config profile anyway?" || {
      warn "WARP profile update cancelled."

      return 0
    }
  fi

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

  ask_panel_auth panel_base token "$default_panel_base" || return $?
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

operation_action_id() {
  case "$1" in
    install_panel|resume_panel_setup|reconfigure_panel_https|install_node|install_panel_node|create_admin_for_existing_panel|setup_subscription_page_for_panel|update_panel|update_node|reinstall_panel_keep_config|reinstall_node_keep_config|remove_panel|remove_panel_with_volumes|remove_stack|remove_stack_with_volumes|backup_all|restore_backup|configure_backup_schedule|issue_cloudflare_wildcard_cert|issue_gcore_wildcard_cert|renew_certificates_dry_run|setup_certbot_auto_renew|remove_certbot_renew_cron|install_warp_native|enable_warp_native|disconnect_warp|remove_warp|add_warp_to_config_profile|remove_warp_from_config_profile|disable_ipv6|enable_ipv6)
      printf '%s' "$1" ;;
    compose_action)
      case "${3:-}" in start|stop|restart) printf 'compose_%s' "$3" ;; *) printf 'inspection' ;; esac ;;
    *) printf 'operation' ;;
  esac
}

operation_recovery_hint() {
  case "$1" in
    install_panel|install_panel_node|resume_panel_setup) printf 'Install -> Continue Panel setup checks completed steps before continuing.' ;;
    reconfigure_panel_https) printf 'Panel -> Configure domain / HTTPS lets you repair the domain, email or certificate.' ;;
    create_admin_for_existing_panel) printf 'Panel -> Create Panel admin can be retried without reinstalling.' ;;
    setup_subscription_page_for_panel) printf 'Panel -> Configure subscription page can finish this step separately.' ;;
    restore_backup) printf 'Check the restore error before starting services. Backup / Restore -> Verify backup can check the archive.' ;;
    backup_all|configure_backup_schedule) printf 'Use Backup / Restore to check the archive and schedule; a failed backup must not be used for recovery.' ;;
    *) printf 'Use System -> Diagnose installation to check the cause before retrying this menu action.' ;;
  esac
}

operation_write_status() (
  [ "${OPERATION_TRACKING_ENABLED:-0}" = 1 ] || return 0
  local status="$1" exit_code="$2" temporary
  umask 077
  mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR" || return 1
  temporary="$(mktemp "$STATE_DIR/.operation.XXXXXX")" || return 1
  {
    printf 'id=%s\naction=%s\nstatus=%s\nexit_code=%s\nupdated=%s\n' "$OPERATION_ID" "$OPERATION_ACTION" "$status" "$exit_code" "$(date +%s)"
    printf 'step=%s\nhint=%s\n' "${OPERATION_STEP:-}" "${OPERATION_HINT:-}" | tr -d '\r'
  } > "$temporary" || { rm -f -- "$temporary"; return 1; }
  mv -f -- "$temporary" "$STATE_DIR/last-operation" || { rm -f -- "$temporary"; return 1; }
)

operation_set_step() {
  [ "${OPERATION_ACTIVE:-0}" = 1 ] || return 0
  OPERATION_STEP="$(printf '%s' "$1" | tr -d '\000-\037\177')"
  if [ "$#" -ge 2 ]; then OPERATION_HINT="$(printf '%s' "$2" | tr -d '\000-\037\177')"; fi
  operation_write_status running 0 || true
}

operation_read_field() {
  [ -f "$STATE_DIR/last-operation" ] && [ ! -L "$STATE_DIR/last-operation" ] || return 0
  LC_ALL=C awk -v key="$1" 'index($0,key "=")==1 {print substr($0,length(key)+2); exit}' "$STATE_DIR/last-operation"
}

# Export only validated metadata. Step descriptions and log text may contain input.
operation_report_last() {
  local action status code updated
  action="$(operation_read_field action)"
  status="$(operation_read_field status)"
  code="$(operation_read_field exit_code)"
  updated="$(operation_read_field updated)"
  case "$action" in compose_start|compose_stop|compose_restart) ;; *) action="$(operation_action_id "${action:-unknown}")" ;; esac
  case "$status" in running|success|failed|cancelled|back) ;; *) status=unknown ;; esac
  [[ "$code" =~ ^[0-9]{1,3}$ ]] || code=unknown
  [[ "$updated" =~ ^[0-9]{1,12}$ ]] || updated=unknown
  printf 'last_action=%s\nlast_status=%s\nlast_exit_code=%s\nlast_updated=%s\n' "$action" "$status" "$code" "$updated"
}

operation_finish() {
  local code="$1" status
  # A subshell may have recorded a more precise step than its parent shell knows.
  if [ "${OPERATION_TRACKING_ENABLED:-0}" = 1 ] && [ "$(operation_read_field id)" = "$OPERATION_ID" ]; then
    OPERATION_STEP="$(operation_read_field step)"
    OPERATION_HINT="$(operation_read_field hint)"
  fi
  case "$code" in 0) status=success ;; 130) status=cancelled ;; 131) status=back ;; *) status=failed ;; esac
  operation_write_status "$status" "$code" || true
}

# Call this and its enclosing menus as simple commands, never in if/! or ||.
# Testing a Bash function's status would disable errexit throughout its body.
run_menu_action() {
  local action_status
  local restore_errexit=0
  local previous_int_trap
  local tracking_enabled="${OPERATION_TRACKING_ENABLED:-0}"
  local action_id action_hint operation_id="${BASHPID}.${RANDOM}.${RANDOM}"
  action_id="$(operation_action_id "$@")"
  action_hint="$(operation_recovery_hint "$action_id")"
  case "$1" in
    diagnose_installation|export_diagnostic_report|show_backup_schedule|list_backups|verify_backup|status_all|show_warp_status|list_certificates|show_support_creator) tracking_enabled=0 ;;
    compose_action) [ "$action_id" != inspection ] || tracking_enabled=0 ;;
  esac
  [[ "$-" != *e* ]] || restore_errexit=1
  previous_int_trap="$(trap -p INT)"

  trap ':' INT
  set +e
  (
    set -Eeuo pipefail
    OPERATION_ACTIVE=1
    OPERATION_TRACKING_ENABLED="$tracking_enabled"
    OPERATION_ID="$operation_id"
    OPERATION_ACTION="$action_id"
    OPERATION_STEP="${action_id//_/ }"
    OPERATION_HINT="$action_hint"
    operation_write_status running 0 || true
    trap 'operation_finish "$?"' EXIT
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
    131) note "Returning to the previous menu." ;;
    *)
      warn "Operation stopped (exit ${action_status}). See the error above or ${LOG_FILE}."
      if [ "$tracking_enabled" = 1 ] && [ "$(operation_read_field id)" = "$operation_id" ]; then
        local failed_step saved_hint
        failed_step="$(operation_read_field step)"
        saved_hint="$(operation_read_field hint)"
        [ -z "$saved_hint" ] || action_hint="$saved_hint"
        [ -z "$failed_step" ] || printf '  Stopped at: %s\n' "$failed_step"
      fi
      note "Completed changes remain in place; later steps were not run."
      printf '  Next: %s\n' "$action_hint"
      ;;
  esac
  return 0
}

show_main_menu() {
  menu_title "Remnawave installer ${SCRIPT_VERSION}"
  show_dashboard || note "Dashboard unavailable. System -> Diagnose installation can check the cause."
  menu_item 1 "Install"
  menu_item 2 "Panel"
  menu_item 3 "Node"
  menu_item 4 "System"
  menu_item 5 "WARP native"
  menu_item 6 "Certificates"
  menu_item 7 "Backup / Restore"
  menu_item_accent 8 "Support Creator"
  menu_item 9 "Diagnose installation"
  menu_item 0 "Exit"
  blank
  micro "Input: /back = previous step; /cancel = menu"
}

show_install_menu() {
  menu_title "Install"
  menu_item 1 "Install Panel"
  menu_item 2 "Install Node"
  menu_item 3 "Install Panel + Node"
  menu_item 4 "Continue Panel setup"
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
  menu_item 12 "Configure domain / HTTPS"
  menu_item 13 "Continue Panel setup"
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
  menu_item 4 "Diagnose installation"
  menu_item 5 "Export diagnostic report"
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
  menu_item 3 "List backups"
  menu_item 4 "Verify backup"
  menu_item 5 "Configure automatic backups"
  menu_item 6 "Show backup schedule"
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
      4) run_menu_action resume_panel_setup ;;
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
      12) run_menu_action reconfigure_panel_https ;;
      13) run_menu_action resume_panel_setup ;;
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
      4) run_menu_action diagnose_installation ;;
      5) run_menu_action export_diagnostic_report ;;
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
      3) run_menu_action list_backups ;;
      4) run_menu_action verify_backup ;;
      5) run_menu_action configure_backup_schedule ;;
      6) run_menu_action show_backup_schedule ;;
      0) return 0 ;;
      *) warn "Invalid menu item." ;;
    esac
  done
}

# MENUS END

# ENTRYPOINT BEGIN

main() {
  case "${1:-}" in
    --scheduled-backup)
      [ "$#" -eq 1 ] || { printf 'Unexpected arguments.\n' >&2; return 2; }
      need_root
      prepare_log
      run_scheduled_backup
      return
      ;;
    '') ;;
    *) printf 'Usage: bash remnawave_installer.sh [--scheduled-backup]\n' >&2; return 2 ;;
  esac
  need_root

  check_os

  prepare_log

  OPERATION_TRACKING_ENABLED=1

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
      9) run_menu_action diagnose_installation ;;
      0) exit 0 ;;
      *) warn "Invalid menu item." ;;
    esac
  done
}

# ENTRYPOINT END

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
