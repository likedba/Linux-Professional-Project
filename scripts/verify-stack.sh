#!/usr/bin/env bash
set -euo pipefail

INVENTORY_PATH=${1:-inventory.ini}

if [[ ! -f "$INVENTORY_PATH" ]]; then
  echo "Inventory not found: $INVENTORY_PATH" >&2
  exit 1
fi

section() {
  echo
  echo "==== $* ===="
}

get_group_hosts() {
  local group="$1"
  awk -v group="$group" '
    $0 ~ /^\[/ { in_group=($0=="["group"]") }
    in_group && $1 !~ /^\[/ && $1 !~ /^$/ {print $1}
  ' "$INVENTORY_PATH"
}

get_group_ips() {
  local group="$1"
  awk -v group="$group" '
    $0 ~ /^\[/ { in_group=($0=="["group"]") }
    in_group && $1 !~ /^\[/ && $1 !~ /^$/ {
      for (i=1;i<=NF;i++) if ($i ~ /^ansible_host=/) {split($i,a,"="); print a[2];}
    }
  ' "$INVENTORY_PATH"
}

section "Connectivity"
ansible -i "$INVENTORY_PATH" all -m ping

section "Frontend: nginx service + open ports"
ansible -i "$INVENTORY_PATH" frontend -m shell -a "systemctl is-active nginx"
ansible -i "$INVENTORY_PATH" frontend -m shell -a "ss -tuln"
ansible -i "$INVENTORY_PATH" frontend -m shell -a "sudo -n ufw status verbose || echo 'ufw check skipped (sudo required)'"

section "Frontend: HTTPS response (self-signed allowed)"
while read -r ip; do
  [[ -z "$ip" ]] && continue
  echo "-- https://$ip --"
  curl -k -I --max-time 5 "https://$ip" || true
  echo
  echo "-- http://$ip (expect redirect) --"
  curl -I --max-time 5 "http://$ip" || true
  echo
  done < <(get_group_ips frontend)

section "Backend: nginx + php-fpm"
ansible -i "$INVENTORY_PATH" backend -m shell -a "systemctl is-active nginx"
ansible -i "$INVENTORY_PATH" backend -m shell -a "systemctl list-units --type=service --all | grep -E 'php[0-9.]*-fpm'"
ansible -i "$INVENTORY_PATH" backend -m shell -a "ss -tuln | grep -E '(:80|:9000)'"

section "Backend: WordPress DB driver load-balancing string"
ansible -i "$INVENTORY_PATH" backend -m shell -a "sudo -n grep -F \"DB_HOST\" /var/www/wordpress/wp-config.php || echo 'wp-config check skipped (sudo required)'"

section "Frontend -> Backend HTTP reachability"
backend_ips=$(get_group_ips backend | paste -sd' ' -)
ansible -i "$INVENTORY_PATH" frontend -m shell -a "for ip in $backend_ips; do echo \"-- http://$ip --\"; curl -I --max-time 5 \"http://$ip\" || true; echo; done"

section "ELK: Docker containers + health"
ansible -i "$INVENTORY_PATH" elk -m shell -a "docker ps --format '{{.Image}}' | grep -E 'elasticsearch|logstash|kibana'"
while read -r ip; do
  [[ -z "$ip" ]] && continue
  echo "-- Elasticsearch https://$ip:9200 --"
  curl -sS --max-time 5 "http://$ip:9200" || true
  echo
  echo "-- Kibana http://$ip:5601 --"
  curl -I --max-time 5 "http://$ip:5601" || true
  echo
  done < <(get_group_ips elk)

section "Zabbix server: services + ports"
ansible -i "$INVENTORY_PATH" zabbix -m shell -a "systemctl is-active zabbix-server zabbix-agent apache2"
ansible -i "$INVENTORY_PATH" zabbix -m shell -a "ss -tuln | grep -E '(:10050|:10051|:80|:443)'"
while read -r ip; do
  [[ -z "$ip" ]] && continue
  echo "-- Zabbix frontend http://$ip/zabbix --"
  curl -I --max-time 5 "http://$ip/zabbix" || true
  echo
  done < <(get_group_ips zabbix)

section "Patroni cluster reachability (PostgreSQL)"
ansible -i "$INVENTORY_PATH" database -m shell -a "ss -tuln | grep -E ':5432'"

section "Frontend: recent nginx errors (502 diagnostics)"
ansible -i "$INVENTORY_PATH" frontend -m shell -a "sudo -n tail -n 50 /var/log/nginx/error.log || echo 'nginx error log check skipped (sudo required)'"

section "Backend: recent nginx/php-fpm errors (502 diagnostics)"
ansible -i "$INVENTORY_PATH" backend -m shell -a "sudo -n tail -n 50 /var/log/nginx/error.log || echo 'nginx error log check skipped (sudo required)'"
ansible -i "$INVENTORY_PATH" backend -m shell -a "sudo -n sh -c 'ls /var/log/php*-fpm.log /var/log/php/*fpm.log 2>/dev/null | head -n 1 | xargs -r tail -n 50' || echo 'php-fpm log check skipped (sudo required)'"

section "Inventory summary"
for group in frontend backend database elk zabbix control; do
  echo "[$group]"
  get_group_hosts "$group" | sed 's/^/  - /'
  echo
  done
