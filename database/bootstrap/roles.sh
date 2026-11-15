#!/bin/sh
set -eu

: "${AUTH_DB_PASSWORD:?AUTH_DB_PASSWORD is required}"
: "${BRANCH_DB_PASSWORD:?BRANCH_DB_PASSWORD is required}"
: "${ATTENDANCE_DB_PASSWORD:?ATTENDANCE_DB_PASSWORD is required}"
: "${MENU_DB_PASSWORD:?MENU_DB_PASSWORD is required}"
: "${INVENTORY_DB_PASSWORD:?INVENTORY_DB_PASSWORD is required}"
: "${CENTRAL_KITCHEN_DB_PASSWORD:?CENTRAL_KITCHEN_DB_PASSWORD is required}"
: "${COST_DB_PASSWORD:?COST_DB_PASSWORD is required}"
: "${SALES_DB_PASSWORD:?SALES_DB_PASSWORD is required}"
: "${TRANSFER_DB_PASSWORD:?TRANSFER_DB_PASSWORD is required}"

psql \
  -v ON_ERROR_STOP=1 \
  -v "auth_password=$AUTH_DB_PASSWORD" \
  -v "branch_password=$BRANCH_DB_PASSWORD" \
  -v "attendance_password=$ATTENDANCE_DB_PASSWORD" \
  -v "menu_password=$MENU_DB_PASSWORD" \
  -v "inventory_password=$INVENTORY_DB_PASSWORD" \
  -v "central_kitchen_password=$CENTRAL_KITCHEN_DB_PASSWORD" \
  -v "cost_password=$COST_DB_PASSWORD" \
  -v "sales_password=$SALES_DB_PASSWORD" \
  -v "transfer_password=$TRANSFER_DB_PASSWORD" \
  -f /bootstrap/roles.sql

role_count=$(psql -Atq -c "SELECT COUNT(*) FROM pg_roles WHERE rolname IN ('auth_app', 'branch_app', 'attendance_app', 'menu_app', 'inventory_app', 'central_kitchen_app', 'cost_app', 'sales_app', 'transfer_app')")
if [ "$role_count" != "9" ]; then
  echo "Role bootstrap created $role_count of 9 expected runtime roles" >&2
  exit 1
fi
echo "Verified all 9 runtime database roles"

