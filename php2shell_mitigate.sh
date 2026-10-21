#!/usr/bin/env bash
# php2shell (CVE-2026-109618 / CVE-2026-109619) 临时缓解脚本
# 只缓解，不是补丁。最终仍需升级到 PHP 8.2.35 / 8.3.36 / 8.4.27 / 8.5.12+
# 用法: sudo bash php2shell_mitigate.sh            应用
#       sudo bash php2shell_mitigate.sh --rollback 回滚到最近一次备份
# 可选环境变量:
#   MAX_BODY=2m        Nginx/PHP 请求体上限 (默认 8m，站点有大文件上传请调大)
#   FPM_ONE_REQ=1      pm.max_requests=1 (默认 1；性能敏感可设 0 改为 50)
#   NO_UPLOAD=1        关闭 PHP 文件上传 (默认 0，会影响上传功能)
set -u
[ "$(id -u)" -eq 0 ] || { echo "请用 root 运行"; exit 1; }

MAX_BODY="${MAX_BODY:-8m}"
FPM_ONE_REQ="${FPM_ONE_REQ:-1}"
NO_UPLOAD="${NO_UPLOAD:-0}"
BK_ROOT=/root/php2shell_backup
TS=$(date +%Y%m%d_%H%M%S)
BK="$BK_ROOT/$TS"
DISABLE="exec,shell_exec,system,passthru,popen,proc_open,pcntl_exec"
PHP_MB=$(echo "$MAX_BODY" | tr -d 'mM')M

log(){ echo -e "\033[32m[+]\033[0m $*"; }
warn(){ echo -e "\033[33m[!]\033[0m $*"; }

# ---------- 找配置 ----------
PHP_INIS=$(ls /www/server/php/*/etc/php.ini /etc/php/*/fpm/php.ini /etc/php/*/apache2/php.ini /etc/php.ini 2>/dev/null)
FPM_CONFS=$(ls /www/server/php/*/etc/php-fpm.conf /etc/php/*/fpm/pool.d/*.conf /etc/php-fpm.d/*.conf 2>/dev/null)
NGINX_CONF=$(ls /www/server/nginx/conf/nginx.conf /etc/nginx/nginx.conf 2>/dev/null | head -1)
NGINX_BIN=$(ls /www/server/nginx/sbin/nginx 2>/dev/null || command -v nginx)

# ---------- 回滚 ----------
if [ "${1:-}" = "--rollback" ]; then
  LAST=$(ls -1d $BK_ROOT/*/ 2>/dev/null | tail -1)
  [ -n "$LAST" ] || { echo "没有找到备份"; exit 1; }
  log "从 $LAST 回滚"
  (cd "$LAST" && find . -type f | while read -r f; do cp -a "$f" "/${f#./}"; echo "  还原 /${f#./}"; done)
  RESTORE=1
else
  RESTORE=0
fi

backup(){ mkdir -p "$BK$(dirname "$1")"; cp -a "$1" "$BK$1"; }

set_ini(){ # file key value
  local f=$1 k=$2 v=$3
  if grep -Eq "^[;[:space:]]*${k}[[:space:]]*=" "$f"; then
    sed -ri "s|^[;[:space:]]*${k}[[:space:]]*=.*|${k} = ${v}|" "$f"
  else
    echo "${k} = ${v}" >> "$f"
  fi
}

if [ $RESTORE -eq 0 ]; then
  [ -n "$PHP_INIS$FPM_CONFS" ] || { warn "没找到 PHP 配置，这台可能没装 PHP"; }

  # ---------- php.ini ----------
  for f in $PHP_INIS; do
    backup "$f"
    set_ini "$f" post_max_size "$PHP_MB"
    set_ini "$f" upload_max_filesize "$PHP_MB"
    set_ini "$f" max_file_uploads 5
    set_ini "$f" max_input_vars 1000
    set_ini "$f" max_input_nesting_level 16
    [ "$NO_UPLOAD" = "1" ] && set_ini "$f" file_uploads Off
    cur=$(grep -E '^[[:space:]]*disable_functions' "$f" | tail -1 | cut -d= -f2- | tr -d ' ')
    new="$cur"
    for fn in ${DISABLE//,/ }; do echo ",$new," | grep -q ",$fn," || new="${new:+$new,}$fn"; done
    set_ini "$f" disable_functions "$new"
    log "已加固 $f"
  done

  # ---------- php-fpm ----------
  if [ "$FPM_ONE_REQ" = "1" ]; then MR=1; else MR=50; fi
  for f in $FPM_CONFS; do
    grep -q '^\[' "$f" || continue
    backup "$f"
    if grep -Eq '^[;[:space:]]*pm\.max_requests' "$f"; then
      sed -ri "s|^[;[:space:]]*pm\.max_requests.*|pm.max_requests = $MR|" "$f"
    else
      echo "pm.max_requests = $MR" >> "$f"
    fi
    log "已设置 pm.max_requests=$MR : $f"
  done

  # ---------- nginx ----------
  if [ -n "$NGINX_CONF" ]; then
    backup "$NGINX_CONF"
    for kv in "client_max_body_size $MAX_BODY" "client_header_buffer_size 4k" "large_client_header_buffers 4 8k"; do
      k=${kv%% *}
      if grep -Eq "^[[:space:]]*$k[[:space:]]" "$NGINX_CONF"; then
        sed -ri "0,/^[[:space:]]*$k[[:space:]].*/s||        $kv;|" "$NGINX_CONF"
      else
        awk -v kv="        $kv;" '!done && /^[ \t]*http([ \t{]|$)/{h=1} {print} h && !done && /\{/{print kv; done=1; h=0}' "$NGINX_CONF" > "$NGINX_CONF.tmp" && cat "$NGINX_CONF.tmp" > "$NGINX_CONF" && rm -f "$NGINX_CONF.tmp"
      fi
    done
    # 站点里单独写的更大上限也压下来
    for v in /www/server/panel/vhost/nginx/*.conf /etc/nginx/sites-enabled/* /etc/nginx/conf.d/*.conf; do
      [ -f "$v" ] && grep -q client_max_body_size "$v" || continue
      backup "$v"; sed -ri "s|client_max_body_size[^;]*;|client_max_body_size $MAX_BODY;|" "$v"
    done
    log "已加固 Nginx: $NGINX_CONF"
  else
    warn "没找到 Nginx（如果是 Apache + mod_php 风险更高，请尽快升级或下线）"
  fi
fi

# ---------- 校验 & 重载 ----------
FAIL=0
if [ -n "$NGINX_BIN" ] && [ -n "$NGINX_CONF" ]; then
  "$NGINX_BIN" -t -c "$NGINX_CONF" >/dev/null 2>&1 || { warn "Nginx 配置检查失败"; FAIL=1; }
fi
for b in /www/server/php/*/sbin/php-fpm /usr/sbin/php-fpm*; do
  [ -x "$b" ] || continue
  "$b" -t >/dev/null 2>&1 || { warn "$b 配置检查失败"; FAIL=1; }
done
if [ $FAIL -eq 1 ] && [ $RESTORE -eq 0 ]; then
  warn "检查失败，自动回滚"; exec bash "$0" --rollback
fi

[ -n "$NGINX_BIN" ] && { "$NGINX_BIN" -s reload 2>/dev/null || systemctl reload nginx 2>/dev/null; }
for s in /etc/init.d/php-fpm-*; do [ -x "$s" ] && "$s" reload >/dev/null 2>&1; done
systemctl list-units --type=service --state=running --no-legend 2>/dev/null | awk '{print $1}' | grep -E '^php.*fpm' | xargs -r -n1 systemctl reload 2>/dev/null
systemctl is-active --quiet apache2 2>/dev/null && systemctl reload apache2
log "已重载服务"

# ---------- 报告 ----------
echo; echo "======== 结果 ========"
for p in /www/server/php/*/bin/php /usr/bin/php /usr/bin/php[0-9]*; do
  case "$(basename "$p")" in *fpm*|*phpize*|*config*|*cgi*|*dbg*|*pear*|*pecl*) continue;; esac
  [ -x "$p" ] || continue
  v=$("$p" -r 'echo PHP_VERSION;' 2>/dev/null </dev/null) && echo "PHP: $p -> $v"
done
echo "备份目录: $BK  (回滚: bash $0 --rollback)"
echo; echo "---- 可疑迹象 ----"
ps -eo user,pid,cmd | awk '$1~/^(www|www-data|nginx|apache)$/' | grep -E ' (sh|bash|dash|curl|wget|nc|python|perl)( |$)' || echo "未发现 web 用户启动的 shell/下载进程"
echo "近 3 天修改的 PHP 文件(前 20):"
find /www/wwwroot /var/www -name '*.php' -mtime -3 2>/dev/null | head -20
echo; warn "这是临时缓解，请尽快把各站点切到 PHP 8.3.36+/8.4.27+"
