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

filter_ips() {
  tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -E '^[0-9a-fA-F:.]+$' || true
}

get_group_ips_ini() {
  local group="$1"
  awk -v group="$group" '
    $0 ~ /^\[/ { in_group=($0=="["group"]") }
    in_group && $1 !~ /^\[/ && $1 !~ /^$/ {
      for (i=1;i<=NF;i++) if ($i ~ /^ansible_host=/) {split($i,a,"="); print a[2];}
    }
  ' "$INVENTORY_PATH"
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
  if command -v ansible-inventory >/dev/null 2>&1; then
    inv_json=$(ansible-inventory -i "$INVENTORY_PATH" --list 2>/dev/null || true)
    if [[ -n "$inv_json" ]]; then
      inv_ips=$(printf "%s" "$inv_json" | python3 -c 'import json,sys
group = sys.argv[1] if len(sys.argv) > 1 else ""
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
hosts = data.get(group, {}).get("hosts", [])
hostvars = data.get("_meta", {}).get("hostvars", {})
for host in hosts:
    ip = hostvars.get(host, {}).get("ansible_host")
    if ip:
        print(ip)
' "$group" || true)
      if [[ -n "${inv_ips// /}" ]]; then
        printf "%s\n" "$inv_ips"
        return 0
      fi
    fi
  fi

  get_group_ips_ini "$group"
}

section "Connectivity"
ansible -i "$INVENTORY_PATH" all -m ping

section "Frontend: nginx service + open ports"
ansible -i "$INVENTORY_PATH" frontend -m shell -a "systemctl is-active nginx"
ansible -i "$INVENTORY_PATH" frontend -m shell -a "ss -tuln"
ansible -i "$INVENTORY_PATH" frontend -m shell -a "sudo -n ufw status verbose 2>/dev/null || echo 'ufw check skipped (sudo required)'"

section "Frontend: HTTPS response (self-signed allowed)"
mapfile -t frontend_ips < <(get_group_ips frontend | filter_ips)
if [[ ${#frontend_ips[@]} -gt 0 ]]; then
  echo "Frontend IPs: ${frontend_ips[*]}"
fi
for ip in "${frontend_ips[@]}"; do
  [[ -z "$ip" ]] && continue
  echo "-- https://$ip --"
  curl -k -I --max-time 5 "https://$ip" || true
  echo
  echo "-- http://$ip (expect redirect) --"
  curl -I --max-time 5 "http://$ip" || true
  echo
done

section "Backend: nginx + php-fpm"
ansible -i "$INVENTORY_PATH" backend -m shell -a "systemctl is-active nginx"
ansible -i "$INVENTORY_PATH" backend -m shell -a "systemctl list-units --type=service --all | grep -E 'php[0-9.]*-fpm'"
ansible -i "$INVENTORY_PATH" backend -m shell -a "ss -tuln | grep -E '(:80|:9000)'"

section "Backend: WordPress DB driver load-balancing string"
ansible -i "$INVENTORY_PATH" backend -m shell -a "sudo -n grep -F \"DB_HOST\" /var/www/wordpress/wp-config.php 2>/dev/null || echo 'wp-config check skipped (sudo required)'"

section "Frontend -> Backend HTTP reachability"
mapfile -t backend_ip_list < <(get_group_ips_ini backend | filter_ips)
if [[ ${#backend_ip_list[@]} -gt 0 ]]; then
  backend_ips="${backend_ip_list[*]}"
  echo "Backend IPs (from INI): ${backend_ips}"
  ansible -i "$INVENTORY_PATH" frontend -m shell -a "for ip in $backend_ips; do echo \"-- http://\\$ip --\"; curl -I --max-time 5 \"http://\\$ip\" || true; echo; done"
else
  echo "No backend IPs found in inventory; skipping reachability check."
fi

section "ELK: Docker containers + health"
ansible -i "$INVENTORY_PATH" elk -m shell -a "sudo -n docker ps --format '{{\"{{\"}}.Image{{\"}}\"}}' 2>/dev/null | grep -E 'elasticsearch|logstash|kibana' || echo 'docker ps check skipped (sudo required)'"
mapfile -t elk_ips < <(get_group_ips elk | filter_ips)
for ip in "${elk_ips[@]}"; do
  [[ -z "$ip" ]] && continue
  echo "-- Elasticsearch https://$ip:9200 --"
  curl -sS --max-time 5 "http://$ip:9200" || true
  echo
  echo "-- Kibana http://$ip:5601 --"
  curl -I --max-time 5 "http://$ip:5601" || true
  echo
done

section "Zabbix server: services + ports"
ansible -i "$INVENTORY_PATH" zabbix -m shell -a "systemctl is-active zabbix-server zabbix-agent apache2"
ansible -i "$INVENTORY_PATH" zabbix -m shell -a "ss -tuln | grep -E '(:10050|:10051|:80|:443)'"
mapfile -t zabbix_ips < <(get_group_ips zabbix | filter_ips)
for ip in "${zabbix_ips[@]}"; do
  [[ -z "$ip" ]] && continue
  echo "-- Zabbix frontend http://$ip/zabbix --"
  curl -I --max-time 5 "http://$ip/zabbix" || true
  echo
done

section "Patroni cluster reachability (PostgreSQL)"
ansible -i "$INVENTORY_PATH" database -m shell -a "ss -tuln | grep -E ':5432'"

section "Frontend: recent nginx errors (502 diagnostics)"
ansible -i "$INVENTORY_PATH" frontend -m shell -a "sudo -n tail -n 50 /var/log/nginx/error.log 2>/dev/null || echo 'nginx error log check skipped (sudo required)'"

section "Backend: recent nginx/php-fpm errors (502 diagnostics)"
ansible -i "$INVENTORY_PATH" backend -m shell -a "sudo -n tail -n 50 /var/log/nginx/error.log 2>/dev/null || echo 'nginx error log check skipped (sudo required)'"
ansible -i "$INVENTORY_PATH" backend -m shell -a "sudo -n sh -c 'ls /var/log/php*-fpm.log /var/log/php/*fpm.log 2>/dev/null | head -n 1 | xargs -r tail -n 50' 2>/dev/null || echo 'php-fpm log check skipped (sudo required)'"

section "Inventory summary"
for group in frontend backend database elk zabbix control; do
  echo "[$group]"
  get_group_hosts "$group" | sed 's/^/  - /'
  echo
  done
