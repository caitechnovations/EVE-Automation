#!/usr/bin/env bash
# Clean EVE-NG Pro automation script
# Creates users + one lab per user safely

set -Eeuo pipefail

# =============================
# MySQL credentials (YOUR SETUP)
# =============================
MYSQL_USER="root"
MYSQL_PASSWORD="Malayalam123#"

# =============================
# Configuration
# =============================
USER_PREFIX="student"        # student1, student2, ...
COUNT=5                     # number of users
START_INDEX=1               # starting index
PASSWORD="ChangeMe123!"     # password for all created users
ROLE="student"              # student / user / admin (schema dependent)
EMAIL_DOMAIN="lab.local"

LAB_SUBDIR="/training"      # under /opt/unetlab/labs
LAB_NAME_PREFIX="Training Lab"

LANG="en"
THEME="default"

PATCH_UI_DISABLE_CLOSE_LAB=0   # set to 1 if needed
DRY_RUN=0                      # set to 1 for dry run

# =============================
# Helpers
# =============================
log() { echo "[`date '+%F %T'`] $*"; }
die() { log "ERROR: $*"; exit 1; }

need() { command -v "$1" >/dev/null || die "Missing command: $1"; }

mysql_cmd() {
  mysql -u "$MYSQL_USER" -p"$MYSQL_PASSWORD" "$DB_NAME" -N -B -e "$1"
}

mysql_cmd_maybe() {
  set +e
  local out
  out=$(mysql -u "$MYSQL_USER" -p"$MYSQL_PASSWORD" "$DB_NAME" -N -B -e "$1" 2>/dev/null)
  set -e
  echo "$out"
}

escape_sql() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\'/\'\'}"
  echo "$s"
}

# =============================
# Preflight
# =============================
need mysql
need sha256sum
need uuidgen

# Detect DB
DB_NAME=""
for db in eve_ng_db unetlab; do
  if mysql -u "$MYSQL_USER" -p"$MYSQL_PASSWORD" -e "SHOW DATABASES LIKE '$db';" 2>/dev/null | grep -q "$db"; then
    DB_NAME="$db"
    break
  fi
done

[[ -n "$DB_NAME" ]] || die "EVE-NG database not found"

log "Using database: $DB_NAME"

LAB_ROOT="/opt/unetlab/labs${LAB_SUBDIR}"
WRAPPER="/opt/unetlab/wrappers/unl_wrapper"
THEME_JS="/opt/unetlab/html/themes/default/js/actions.js"

PASS_HASH=$(echo -n "$PASSWORD" | sha256sum | awk '{print $1}')

mkdir -p "$LAB_ROOT"

# =============================
# Schema checks
# =============================
table_has() { mysql_cmd_maybe "SHOW TABLES LIKE '$1';" | grep -q "$1"; }
col_has() { mysql_cmd_maybe "SHOW COLUMNS FROM users LIKE '$1';" | grep -q "$1"; }

table_has users || die "users table missing"

# =============================
# Build SQL insert dynamically
# =============================
build_user_sql() {
  local user="$1"
  local email="$2"

  cols=()
  vals=()

  col_has username && cols+=("username") && vals+=("'$(escape_sql "$user")'")
  col_has password && cols+=("password") && vals+=("'$PASS_HASH'")
  col_has email && cols+=("email") && vals+=("'$(escape_sql "$email")'")
  col_has role && cols+=("role") && vals+=("'$ROLE'")
  col_has lang && cols+=("lang") && vals+=("'$LANG'")
  col_has theme && cols+=("theme") && vals+=("'$THEME'")
  col_has active && cols+=("active") && vals+=("1")

  echo "INSERT INTO users ($(IFS=,; echo "${cols[*]}")) VALUES ($(IFS=,; echo "${vals[*]}"));"
}

user_exists() {
  mysql_cmd_maybe "SELECT username FROM users WHERE username='$1' LIMIT 1;" | grep -q .
}

# =============================
# Main loop
# =============================
END=$((START_INDEX + COUNT - 1))

for i in $(seq $START_INDEX $END); do
  USERNAME="${USER_PREFIX}${i}"
  EMAIL="${USERNAME}@${EMAIL_DOMAIN}"

  if user_exists "$USERNAME"; then
    log "User exists, skipping: $USERNAME"
  else
    SQL=$(build_user_sql "$USERNAME" "$EMAIL")
    log "Creating user: $USERNAME"
    [[ "$DRY_RUN" == "1" ]] && echo "$SQL" || mysql_cmd "$SQL"
  fi

  LAB_FILE="${LAB_ROOT}/${USERNAME}.unl"
  if [[ ! -f "$LAB_FILE" ]]; then
    UUID=$(uuidgen)
    log "Creating lab: $LAB_FILE"
    [[ "$DRY_RUN" == "1" ]] || cat > "$LAB_FILE" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<lab name="${LAB_NAME_PREFIX} - ${USERNAME}" id="${UUID}" version="1" lock="0">
  <topology></topology>
  <objects></objects>
</lab>
EOF
  fi
done

# =============================
# Permissions
# =============================
if [[ "$DRY_RUN" != "1" ]]; then
  chown -R www-data:www-data "$LAB_ROOT"
  chmod -R 775 "$LAB_ROOT"
  [[ -x "$WRAPPER" ]] && "$WRAPPER" -a fixpermissions
fi

# =============================
# Optional UI patch
# =============================
if [[ "$PATCH_UI_DISABLE_CLOSE_LAB" == "1" ]]; then
  SRC="$(dirname "$0")/automate/actions.js"
  if [[ -f "$SRC" ]]; then
    log "Patching UI to disable Close Lab"
    [[ "$DRY_RUN" == "1" ]] || cp "$THEME_JS" "${THEME_JS}.bak.$(date +%s)"
    [[ "$DRY_RUN" == "1" ]] || cp "$SRC" "$THEME_JS"
    systemctl restart apache2
  fi
fi

log "Completed successfully"
