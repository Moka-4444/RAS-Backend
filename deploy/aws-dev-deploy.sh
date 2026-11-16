#!/usr/bin/env bash
set -euo pipefail
if [[ -f /etc/ras-backend-deploy.env ]]; then
  set -a
  # This file contains only development endpoints and parameter names, never secret values.
  source /etc/ras-backend-deploy.env
  set +a
fi

usage() {
  echo "Usage: ras-backend-deploy.sh migrate <image-sha> | auth-api|branch-api|attendance-api|menu-api|central-kitchen-api|inventory-api|cost-api|sales-api|transfer-api|reports-api <image-sha>" >&2
  exit 2
}
[[ $# -eq 2 ]] || usage
operation="$1"
image_tag="$2"
[[ "$image_tag" =~ ^[A-Fa-f0-9]{7,64}$ ]] || { echo "Image tag must be a commit SHA." >&2; exit 2; }
: "${AWS_REGION:?AWS_REGION is required}"
: "${APP_SECRET_PARAMETER_NAME:?APP_SECRET_PARAMETER_NAME is required}"
: "${DATABASE_MASTER_PASSWORD_PARAMETER_NAME:?DATABASE_MASTER_PASSWORD_PARAMETER_NAME is required}"
: "${DATABASE_MASTER_USERNAME:?DATABASE_MASTER_USERNAME is required}"
: "${DATABASE_ENDPOINT:?DATABASE_ENDPOINT is required}"
: "${DB_NAME:?DB_NAME is required}"
: "${MIGRATION_IMAGE_REPOSITORY:?MIGRATION_IMAGE_REPOSITORY is required}"

secret_json="$(aws ssm get-parameter --region "$AWS_REGION" --name "$APP_SECRET_PARAMETER_NAME" --with-decryption --query Parameter.Value --output text)"
master_password="$(aws ssm get-parameter --region "$AWS_REGION" --name "$DATABASE_MASTER_PASSWORD_PARAMETER_NAME" --with-decryption --query Parameter.Value --output text)"
for key in JWT_SECRET AUTH_DB_PASSWORD BRANCH_DB_PASSWORD ATTENDANCE_DB_PASSWORD MENU_DB_PASSWORD CENTRAL_KITCHEN_DB_PASSWORD INVENTORY_DB_PASSWORD COST_DB_PASSWORD SALES_DB_PASSWORD TRANSFER_DB_PASSWORD REPORTS_DB_PASSWORD SEED_CEO_EMAIL SEED_CEO_PASSWORD; do
  jq -e --arg key "$key" '.[$key] | strings | length > 0' <<<"$secret_json" >/dev/null || { echo "Required app secret field missing: $key" >&2; exit 1; }
done
jq -e '.JWT_SECRET | test("^[A-Za-z0-9._~-]{32,}$")' <<<"$secret_json" >/dev/null || { echo "JWT_SECRET must be at least 32 URL-safe characters." >&2; exit 1; }
jq -e '.SEED_CEO_EMAIL | test("^[^[:space:]@]+@[^[:space:]@]+\\.[^[:space:]@]+$")' <<<"$secret_json" >/dev/null || { echo "SEED_CEO_EMAIL is invalid." >&2; exit 1; }
jq -e '[.AUTH_DB_PASSWORD, .BRANCH_DB_PASSWORD, .ATTENDANCE_DB_PASSWORD, .MENU_DB_PASSWORD, .CENTRAL_KITCHEN_DB_PASSWORD, .INVENTORY_DB_PASSWORD, .COST_DB_PASSWORD, .SALES_DB_PASSWORD, .TRANSFER_DB_PASSWORD, .REPORTS_DB_PASSWORD, .SEED_CEO_PASSWORD] | all(strings and (test("^[A-Za-z0-9._~@-]+$")))' <<<"$secret_json" >/dev/null || { echo "Application passwords contain unsupported characters." >&2; exit 1; }
[[ -n "$DATABASE_MASTER_USERNAME" && -n "$master_password" ]] || { echo "RDS master credentials are not configured." >&2; exit 1; }

secret_dir=/etc/ras-backend
install -d -m 0700 "$secret_dir"
umask 077
cleanup_secret_files() {
  rm -f "$secret_dir/migration.env" "$secret_dir/goose.env"
}
trap cleanup_secret_files EXIT

write_app_env() {
  local service="$1" role="$2" password_key="$3" port="$4" file="$5"
  if [[ "$service" =~ ^(auth-api|branch-api|attendance-api|menu-api)$ ]]; then
    jq -er --arg service "$service" --arg role "$role" --arg password_key "$password_key" --arg port "$port" --arg host "$DATABASE_ENDPOINT" --arg db "$DB_NAME" '
      . as $s |
      if (($s.JWT_SECRET | test("^[A-Za-z0-9._~-]{32,}$")) and ($s[$password_key] | test("^[A-Za-z0-9._~@-]+$"))) then
        ("PORT=\($port)\nDB_HOST=\($host)\nDB_PORT=5432\nDB_NAME=\($db)\nDB_USER=\($role)\nDB_PASSWORD=\($s[$password_key])\nDB_SSLMODE=require\nJWT_SECRET=\($s.JWT_SECRET)" + (if $service == "auth-api" then "\nAPP_ENV=development\nSEED_CEO_NAME=\($s.SEED_CEO_NAME // "CEO")\nSEED_CEO_EMAIL=\($s.SEED_CEO_EMAIL)\nSEED_CEO_PASSWORD=\($s.SEED_CEO_PASSWORD)" else "" end))
      else error("JWT or database password is invalid") end
    ' <<<"$secret_json" >"$file"
  else
    jq -er --arg role "$role" --arg password_key "$password_key" --arg port "$port" --arg host "$DATABASE_ENDPOINT" --arg db "$DB_NAME" '
      . as $s |
      if ($s[$password_key] | test("^[A-Za-z0-9._~@-]+$")) then
        ($s[$password_key] | @uri) as $encoded_password |
        ("DATABASE_URL=postgres://\($role):\($encoded_password)@\($host):5432/\($db)?sslmode=require" + (if $port == "" then "" else "\nPORT=\($port)" end))
      else error("Database password is invalid") end
    ' <<<"$secret_json" >"$file"
  fi
  chmod 0600 "$file"
}

if [[ "$operation" == "migrate" ]]; then
  repo="$MIGRATION_IMAGE_REPOSITORY"
  registry="${repo%%/*}"
  aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$registry" >/dev/null
  image="$repo:$image_tag"
  docker pull "$image" >/dev/null
  master_user="$DATABASE_MASTER_USERNAME"
  printf '%s\n' \
    "PGHOST=$DATABASE_ENDPOINT" \
    "PGPORT=5432" \
    "PGDATABASE=$DB_NAME" \
    "PGUSER=$master_user" \
    "PGPASSWORD=$master_password" \
    "AUTH_DB_PASSWORD=$(jq -er '.AUTH_DB_PASSWORD' <<<"$secret_json")" \
    "BRANCH_DB_PASSWORD=$(jq -er '.BRANCH_DB_PASSWORD' <<<"$secret_json")" \
    "ATTENDANCE_DB_PASSWORD=$(jq -er '.ATTENDANCE_DB_PASSWORD' <<<"$secret_json")" \
    "MENU_DB_PASSWORD=$(jq -er '.MENU_DB_PASSWORD' <<<"$secret_json")" \
    "CENTRAL_KITCHEN_DB_PASSWORD=$(jq -er '.CENTRAL_KITCHEN_DB_PASSWORD' <<<"$secret_json")" \
    "INVENTORY_DB_PASSWORD=$(jq -er '.INVENTORY_DB_PASSWORD' <<<"$secret_json")" \
    "COST_DB_PASSWORD=$(jq -er '.COST_DB_PASSWORD' <<<"$secret_json")" \
    "SALES_DB_PASSWORD=$(jq -er '.SALES_DB_PASSWORD' <<<"$secret_json")" \
    "TRANSFER_DB_PASSWORD=$(jq -er '.TRANSFER_DB_PASSWORD' <<<"$secret_json")" \
    "REPORTS_DB_PASSWORD=$(jq -er '.REPORTS_DB_PASSWORD' <<<"$secret_json")" \
    >"$secret_dir/migration.env"
  chmod 0600 "$secret_dir/migration.env"
  docker run --rm --network host --env-file "$secret_dir/migration.env" --entrypoint psql "$image" -v ON_ERROR_STOP=1 -f /database/bootstrap/roles.sql
  encoded_master_user="$(jq -nr --arg value "$master_user" '$value | @uri')"
  encoded_master_password="$(jq -nr --arg value "$master_password" '$value | @uri')"
  goose_dbstring="postgres://$encoded_master_user:$encoded_master_password@$DATABASE_ENDPOINT:5432/$DB_NAME?sslmode=require"
  printf '%s\n' \
    'GOOSE_DRIVER=postgres' \
    "GOOSE_DBSTRING=$goose_dbstring" \
    'GOOSE_MIGRATION_DIR=/migrations' \
    'GOOSE_TABLE=goose_db_version' \
    >"$secret_dir/goose.env"
  chmod 0600 "$secret_dir/goose.env"
  docker run --rm --network host --env-file "$secret_dir/goose.env" "$image" -dir /migrations up
  rm -f "$secret_dir/migration.env" "$secret_dir/goose.env"
  echo "Central migrations applied using image $image_tag."
  exit 0
fi

case "$operation" in
  auth-api) repo="${AUTH_IMAGE_REPOSITORY:?AUTH_IMAGE_REPOSITORY is required}"; role=auth_app; password_key=AUTH_DB_PASSWORD; port=9001 ;;
  branch-api) repo="${BRANCH_IMAGE_REPOSITORY:?BRANCH_IMAGE_REPOSITORY is required}"; role=branch_app; password_key=BRANCH_DB_PASSWORD; port=9002 ;;
  attendance-api) repo="${ATTENDANCE_IMAGE_REPOSITORY:?ATTENDANCE_IMAGE_REPOSITORY is required}"; role=attendance_app; password_key=ATTENDANCE_DB_PASSWORD; port=9003 ;;
  menu-api) repo="${MENU_IMAGE_REPOSITORY:?MENU_IMAGE_REPOSITORY is required}"; role=menu_app; password_key=MENU_DB_PASSWORD; port=9005 ;;
  central-kitchen-api) repo="${CENTRAL_KITCHEN_IMAGE_REPOSITORY:?CENTRAL_KITCHEN_IMAGE_REPOSITORY is required}"; role=central_kitchen_app; password_key=CENTRAL_KITCHEN_DB_PASSWORD; port=9004 ;;
  inventory-api) repo="${INVENTORY_IMAGE_REPOSITORY:?INVENTORY_IMAGE_REPOSITORY is required}"; role=inventory_app; password_key=INVENTORY_DB_PASSWORD; port=9010 ;;
  cost-api) repo="${COST_IMAGE_REPOSITORY:?COST_IMAGE_REPOSITORY is required}"; role=cost_app; password_key=COST_DB_PASSWORD; port=9007 ;;
  sales-api) repo="${SALES_IMAGE_REPOSITORY:?SALES_IMAGE_REPOSITORY is required}"; role=sales_app; password_key=SALES_DB_PASSWORD; port=9006 ;;
  transfer-api) repo="${TRANSFER_IMAGE_REPOSITORY:?TRANSFER_IMAGE_REPOSITORY is required}"; role=transfer_app; password_key=TRANSFER_DB_PASSWORD; port=9008 ;;
  reports-api) repo="${REPORTS_IMAGE_REPOSITORY:?REPORTS_IMAGE_REPOSITORY is required}"; role=reports_app; password_key=REPORTS_DB_PASSWORD; port=9009 ;;
  *) usage ;;
esac
registry="${repo%%/*}"
aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$registry" >/dev/null
image="$repo:$image_tag"
docker pull "$image" >/dev/null
env_file="$secret_dir/$operation.env"
write_app_env "$operation" "$role" "$password_key" "$port" "$env_file"
if docker container inspect "$operation" >/dev/null 2>&1; then docker stop --time 15 "$operation" >/dev/null; docker rm "$operation" >/dev/null; fi
docker run -d --restart unless-stopped --name "$operation" --env-file "$env_file" -p "$port:$port" "$image" >/dev/null
rm -f "$env_file"
health_path=/health
if [[ "$operation" == "inventory-api" || "$operation" == "transfer-api" ]]; then health_path=/healthz; fi
for _ in $(seq 1 30); do
  if curl --fail --silent --show-error --max-time 3 "http://127.0.0.1:$port$health_path" >/dev/null; then
    echo "Started $operation from immutable image $image_tag; local health check passed."
    exit 0
  fi
  sleep 2
done
docker logs --tail 100 "$operation" >&2 || true
echo "Health check failed for $operation at $health_path." >&2
exit 1
