#!/usr/bin/env bash
# kaze installer for Linux with systemd.
#
#   bash install.sh install --type xboard --server-type vless --node-id 1 \
#        --panel-url https://panel.example.com --panel-key TOKEN [--license KAZE1...] [key=value ...]
#   bash install.sh --api-host https://panel.example.com --node-id 1 --api-key TOKEN
#        (the one-click command V2board shows for a v2node node, with this script's URL)
#   bash install.sh update [--if-newer]     (keeps the previous binary; rolls back if the new one fails)
#   bash install.sh rollback
#   bash install.sh uninstall [--name b]
#
# A second panel on the same machine is a second instance: add --name b to
# install, and the service is kaze-b with its configuration in /etc/kaze-b
# ("kaze -n b" controls it). Any other setting from kaze.conf can be
# appended as key=value.
# To install a binary you already have instead of downloading: --binary /path/to/kaze
set -euo pipefail

# Where release binaries are published. Override with KAZE_DOWNLOAD.
DOWNLOAD="${KAZE_DOWNLOAD:-https://github.com/kazeproxy/kaze-release/releases/latest/download}"
RELEASES=https://github.com/kazeproxy/kaze-release
SCRIPT="$RELEASES/raw/main/install.sh"

# The program lives in its own directory; "kaze" on the PATH is the control
# script with the menu, and "kz" is the same script under its old name.
BIN=/usr/local/kaze/kaze
CTL=/usr/local/bin/kaze
CTL_ALIAS=/usr/local/bin/kz
OLD_BIN=/usr/local/bin/kaze # where releases before v0.4.3 put the program
TIMER=/etc/systemd/system/kaze-update.timer

die() { echo "error: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "run as root"
command -v systemctl >/dev/null || die "systemd is required"

# The instance: "" is the first (service kaze, /etc/kaze); a name makes a
# second one (service kaze-NAME, /etc/kaze-NAME) sharing the program.
NAME=""
set_name() {
  NAME=$1
  [ -z "$NAME" ] || [[ "$NAME" =~ ^[a-z0-9]{1,16}$ ]] || die "--name must be 1-16 lowercase letters or digits"
  [ "$NAME" != update ] || die "--name update is taken"
  SVC=kaze${NAME:+-$NAME}
  DIR=/etc/$SVC
  CONF=$DIR/kaze.conf
  UNIT=/etc/systemd/system/$SVC.service
}
set_name ""
# Every instance installed here: the first, then the named ones. Only
# units this script wrote count; kaze-bot or kaze-auth on the same machine
# are not nodes.
instances() {
  local u
  for u in /etc/systemd/system/kaze.service /etc/systemd/system/kaze-*.service; do
    [ -f "$u" ] || continue
    grep -q "^ExecStart=$BIN -c /etc/kaze" "$u" || continue
    u=${u##*/}; echo "${u%.service}"
  done
}
LOCAL_SCRIPT=/usr/local/kaze/install.sh

arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    *) die "unsupported architecture $(uname -m)" ;;
  esac
}

fetch() { # url dest
  if command -v curl >/dev/null; then curl -fsSL --retry 3 --max-time 600 -o "$2" "$1"
  elif command -v wget >/dev/null; then wget -q --timeout=600 -O "$2" "$1" || { rm -f "$2"; return 1; }
  else die "curl or wget is required"; fi
}

install_binary() { # [local-file]
  # The directory and the program must stay world-readable whatever the
  # umask: the service runs as the kaze user.
  mkdir -p "$(dirname "$BIN")"
  chmod 755 "$(dirname "$BIN")"
  # In the program's own directory: /tmp may be noexec, and the final move
  # must be a rename on the same filesystem.
  local tmp; tmp=$(mktemp "$(dirname "$BIN")/.kaze.XXXXXX")
  if [ -n "${1:-}" ]; then
    cp "$1" "$tmp"
  else
    local name="kaze-linux-$(arch)" sums
    echo "downloading kaze for linux/$(arch)"
    fetch "$DOWNLOAD/$name" "$tmp"
    # The release's checksums come from the same place: a mirror or a
    # proxy that hands out another file is caught here.
    sums=$(mktemp "$(dirname "$BIN")/.sums.XXXXXX")
    fetch "$DOWNLOAD/SHA256SUMS" "$sums" || { rm -f "$tmp" "$sums"; die "cannot download SHA256SUMS"; }
    local want; want=$(awk -v n="$name" '$2==n || $2=="*"n {print $1}' "$sums"); rm -f "$sums"
    [ -n "$want" ] || { rm -f "$tmp"; die "SHA256SUMS has no entry for $name"; }
    local got; got=$(sha256sum "$tmp" | awk '{print $1}')
    [ "$got" = "$want" ] || { rm -f "$tmp"; die "checksum mismatch for $name: the download is not the released file"; }
  fi
  chmod 755 "$tmp"
  "$tmp" -v >/dev/null 2>&1 || { rm -f "$tmp"; die "the binary does not run on this machine"; }
  [ ! -x "$BIN" ] || cp -p "$BIN" "$BIN.prev" # the version being replaced, for kaze rollback
  mv "$tmp" "$BIN"
  chmod 755 "$BIN"
  echo "installed $("$BIN" -v)"
  # A copy of this script, for rollback and uninstall without the network.
  curl -fsSL --max-time 60 -o "$LOCAL_SCRIPT.tmp" "$SCRIPT" 2>/dev/null && [ -s "$LOCAL_SCRIPT.tmp" ] && { mv "$LOCAL_SCRIPT.tmp" "$LOCAL_SCRIPT"; chmod 755 "$LOCAL_SCRIPT"; } || rm -f "$LOCAL_SCRIPT.tmp"
}

write_ctl() {
  # Written beside and renamed over: $CTL may still be the running program
  # on a machine installed before v0.4.3, which cannot be overwritten.
  cat > "$CTL.tmp" <<'CTL_EOF'
#!/usr/bin/env bash
# kaze (also kz): day-to-day control of the kaze service. With no arguments,
# a menu. The program itself is /usr/local/kaze/kaze. A second instance
# (another panel on this machine) is "kaze -n NAME ...".
SCRIPT=https://github.com/kazeproxy/kaze-release/raw/main/install.sh
NAME=${KAZE_NAME:-}
if [ "${1:-}" = -n ]; then NAME=${2:-}; shift 2; fi
SVC=kaze${NAME:+-$NAME}
DIR=/etc/$SVC
CONF=$DIR/kaze.conf
[ -z "$NAME" ] || [ -f "$CONF" ] || { echo "no instance named $NAME (installed ones: $(ls -d /etc/kaze-*/ 2>/dev/null | sed 's#/etc/kaze-##; s#/##' | tr '\n' ' '))" >&2; exit 1; }

usage() {
  echo "usage: kaze [-n 实例] [menu]|start|stop|restart|status|enable|disable|log [lines]|follow|check|license|geo|version|update|rollback|auto-update [on|off]|config [key=value ...]|instances|add"
}

# instances lists every instance on this machine (units this script wrote).
instances() {
  local u
  for u in /etc/systemd/system/kaze.service /etc/systemd/system/kaze-*.service; do
    [ -f "$u" ] || continue
    grep -q "^ExecStart=/usr/local/kaze/kaze -c /etc/kaze" "$u" || continue
    u=${u##*/}; echo "${u%.service}"
  done
}

# installer runs the install script: the latest one when it can be
# fetched whole, else the copy kept from the last install, so rollback and
# uninstall work offline and a failed download never runs an empty script.
installer() {
  local t; t=$(mktemp)
  if curl -fsSL --max-time 60 -o "$t" "$SCRIPT" 2>/dev/null && [ -s "$t" ] && head -1 "$t" | grep -q '^#!'; then
    bash "$t" "$@"; local rc=$?; rm -f "$t"; return $rc
  fi
  rm -f "$t"
  [ -s /usr/local/kaze/install.sh ] || { echo "cannot download the install script and no local copy is kept" >&2; return 1; }
  bash /usr/local/kaze/install.sh "$@"
}

# add installs a second instance for another panel, asking what the panel's
# install command would carry.
add() {
  local name mode url key id lic
  echo "给这台机器再加一个面板（另一个 kaze 实例，和现有的互不影响）。"
  read -rp "实例名（1-16 位小写字母或数字，例如 b）：" name
  [[ "$name" =~ ^[a-z0-9]{1,16}$ ]] || { echo "实例名不合法"; return 1; }
  [ ! -f "/etc/kaze-$name/kaze.conf" ] || { echo "实例 $name 已存在，用 kaze -n $name 操作它"; return 1; }
  read -rp "对接方式：1 = Xboard 机器模式，2 = 普通模式（节点 ID）[1]：" mode
  read -rp "面板地址（https://...）：" url
  [ -n "$url" ] || { echo "面板地址不能为空"; return 1; }
  if [ "${mode:-1}" = 1 ]; then
    read -rp "机器 ID：" id
    read -rp "机器令牌：" key
    [ -n "$id" ] && [ -n "$key" ] || { echo "机器 ID 和令牌不能为空"; return 1; }
    read -rp "授权码（没有就留空）：" lic
    installer install --name "$name" --mode machine --panel "$url" --token "$key" --machine-id "$id" ${lic:+--license "$lic"}
  else
    local type stype
    read -rp "面板类型 xboard / v2board / v2node / ppanel [xboard]：" type
    read -rp "节点 ID（多个用逗号）：" id
    read -rp "通讯密钥：" key
    [ -n "$id" ] && [ -n "$key" ] || { echo "节点 ID 和通讯密钥不能为空"; return 1; }
    if [ "${type:-xboard}" != xboard ] && [ "${type:-xboard}" != v2node ]; then read -rp "协议（server_type，例如 vless）：" stype; fi
    read -rp "授权码（没有就留空）：" lic
    installer install --name "$name" --type "${type:-xboard}" --node-id "$id" --panel-url "$url" --panel-key "$key" ${stype:+--server-type "$stype"} ${lic:+--license "$lic"}
  fi
}

pause() { echo; read -rp "按回车返回菜单..." _; }

menu() {
  while true; do
    local state auto boot
    systemctl is-active --quiet "$SVC" && state="\033[32m运行中\033[0m" || state="\033[31m已停止\033[0m"
    systemctl is-enabled --quiet kaze-update.timer 2>/dev/null && auto="开" || auto="关"
    systemctl is-enabled --quiet "$SVC" 2>/dev/null && boot="开" || boot="关"
    local inst=""; [ -z "$NAME" ] || inst="   实例：$NAME"
    local others; others=$(instances | grep -vx "$SVC" | sed 's/^kaze-//' | tr '\n' ' ')
    [ -z "$others" ] || inst="$inst   其他实例：$others（kaze -n 名字）"
    clear 2>/dev/null
    echo -e "
  kaze $(/usr/local/kaze/kaze -v 2>/dev/null | awk '{print $2}')   状态：$state   自动升级：$auto   开机自启：$boot$inst

  —— 服务 ——
   1. 查看运行状态
   2. 启动
   3. 停止
   4. 重启

  —— 日志与检查 ——
   5. 查看最近日志
   6. 实时查看日志（Ctrl+C 返回）
   7. 对着面板检查配置

  —— 配置 ——
   8. 查看当前配置
   9. 修改配置
  10. 查看授权状态
  11. 更新 geo 数据

  —— 版本 ——
  12. 升级到最新版
  13. 回滚到上一个版本
  14. 自动升级：开 / 关
  15. 查看版本

  —— 其他 ——
  16. 开机自启：开 / 关
  17. 卸载 kaze
  18. 再加一个面板（第二个实例）
   0. 退出
"
    read -rp "  请输入数字：" n
    echo
    case "$n" in
      1)  run status; pause ;;
      2)  run start && echo "已启动"; pause ;;
      3)  run stop && echo "已停止"; pause ;;
      4)  run restart && echo "已重启"; pause ;;
      5)  run log 100; pause ;;
      6)  trap 'true' INT; run follow; trap - INT ;;
      7)  run check; pause ;;
      8)  run config; pause ;;
      9)  echo "格式：配置项=值，多个用空格隔开，例如 user_speed_limit=100 forbidden_bit_torrent=true"
          read -ra kvs -p "请输入："
          if [ ${#kvs[@]} -gt 0 ]; then
            run config "${kvs[@]}" && { read -rp "现在重启让设置生效？[Y/n] " yn; case "$yn" in n|N) ;; *) run restart && echo "已重启" ;; esac; }
          fi
          pause ;;
      10) run license; pause ;;
      11) run geo; pause ;;
      12) run update; pause ;;
      13) run rollback; pause ;;
      14) if [ "$auto" = 开 ]; then run auto-update off; else run auto-update on; fi; pause ;;
      15) run version; pause ;;
      16) if [ "$boot" = 开 ]; then run disable && echo "开机自启已关闭"; else run enable && echo "开机自启已开启"; fi; pause ;;
      17) if [ -n "$NAME" ]; then
            read -rp "确认移除实例 $NAME？配置会保留在 $DIR，程序和其他实例不受影响。输入 yes 确认：" yn
            if [ "$yn" = yes ]; then installer uninstall --name "$NAME"; exit 0; fi
          else
            read -rp "确认卸载 kaze？会停掉所有实例，配置保留在 /etc/kaze*。输入 yes 确认：" yn
            if [ "$yn" = yes ]; then installer uninstall; exit 0; fi
          fi ;;
      18) add; pause ;;
      0|q|Q) exit 0 ;;
      *)  ;;
    esac
  done
}

run() {
case "${1:-}" in
  start|stop|restart|status) systemctl "$1" "$SVC" ;;
  enable|disable)            systemctl "$1" "$SVC" ;;
  log)     journalctl -u "$SVC" -n "${2:-100}" --no-pager ;;
  follow)  journalctl -u "$SVC" -f ;;
  check)   sudo -u kaze /usr/local/kaze/kaze -c "$CONF" -check ;;
  license) /usr/local/kaze/kaze -c "$CONF" -license ;;
  geo)     /usr/local/kaze/kaze -c "$CONF" -update-geo && chown kaze:kaze "$DIR"/*.dat ;;
  instances) instances | sed 's/^kaze$/kaze（默认实例，\/etc\/kaze）/; s/^kaze-\(.*\)$/\1（kaze -n \1，\/etc\/kaze-\1）/' ;;
  add)     add ;;
  version) /usr/local/kaze/kaze -v ;;
  -*)      exec /usr/local/kaze/kaze "$@" ;; # flags go to the program: kaze -v, kaze -reality-keypair
  update)   shift; installer update "$@" ;;
  rollback) installer rollback ;;
  auto-update)
    case "${2:-status}" in
      on)  systemctl enable --now kaze-update.timer && echo "daily auto-update on; check with: kaze auto-update status" ;;
      off) systemctl disable --now kaze-update.timer && echo "auto-update off" ;;
      *)   systemctl is-enabled --quiet kaze-update.timer 2>/dev/null && { echo "auto-update: on"; systemctl list-timers kaze-update.timer --no-pager | sed -n 2p; } || echo "auto-update: off (turn on with: kaze auto-update on)" ;;
    esac ;;
  config)
    shift
    if [ $# -eq 0 ]; then grep -v '^[[:space:]]*#' "$CONF" | grep -v '^[[:space:]]*$' | sed -E 's/^(webapi_key|panel_key|license_key|machine_token)=.*/\1=********/'; return 0; fi
    for kv in "$@"; do
      key=${kv%%=*}; val=${kv#*=}
      [ "$key" != "$kv" ] || { echo "expected key=value, got $kv" >&2; return 1; }
      [[ "$key" =~ ^[a-z0-9_]+$ ]] || { echo "not a setting name: $key" >&2; return 1; }
      # Replace the first line in the common part (before any [node N]
      # section) that sets or comments out this key, else append it there.
      # The value goes through the environment: awk does not interpret it.
      K="$key" V="$val" awk 'BEGIN{d=0; sec=0; k=ENVIRON["K"]; v=ENVIRON["V"]}
        /^[[:space:]]*\[/ { if (!d) { print k "=" v; d=1 } sec=1 }
        { line=$0; sub(/^[#[:space:]]*/, "", line) }
        !d && !sec && index(line, k "=")==1 { print k "=" v; d=1; next }
        { print }
        END { if (!d) print k "=" v }' "$CONF" > "$CONF.tmp" && mv "$CONF.tmp" "$CONF"
    done
    chown kaze:kaze "$CONF"; chmod 600 "$CONF"
    echo "saved; apply with: kaze${NAME:+ -n $NAME} restart" ;;
  menu|"")
    if [ -t 0 ]; then menu; else usage; fi ;;
  *) usage ;;
esac
}

run "$@"
CTL_EOF
  chmod 755 "$CTL.tmp"
  mv "$CTL.tmp" "$CTL"
  ln -sf "$CTL" "$CTL_ALIAS"
}

write_unit() {
  cat > "$UNIT" <<UNIT_EOF
[Unit]
Description=kaze node${NAME:+ ($NAME)}
After=network-online.target
Wants=network-online.target

[Service]
User=kaze
Group=kaze
ExecStart=$BIN -c $CONF
Restart=always
RestartSec=3
LimitNOFILE=1048576
# Listening below port 1024, and setting up the port-hopping forward rules,
# without running as root.
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_ADMIN
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=$DIR

[Install]
WantedBy=multi-user.target
UNIT_EOF
  chmod 644 "$UNIT"
  # Daily update, off until "kaze auto-update on". The random delay spreads a
  # fleet's updates over hours, so a bad release never takes every node at once.
  cat > /etc/systemd/system/kaze-update.service <<UPD_EOF
[Unit]
Description=kaze update
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/kaze update --if-newer
UPD_EOF
  cat > "$TIMER" <<TIMER_EOF
[Unit]
Description=Daily kaze update

[Timer]
OnCalendar=daily
RandomizedDelaySec=6h
Persistent=true

[Install]
WantedBy=timers.target
TIMER_EOF
  systemctl daemon-reload
}

cmd_install() {
  local binary="" type=xboard server_type="" node_id="" url="" key="" license="" mode="" machine_id=""
  local extra=() v2node="" type_set=""
  for a in "$@"; do [ "$a" != --type ] || type_set=1; done
  while [ $# -gt 0 ]; do
    case "$1" in
      --name)        set_name "$2"; shift 2 ;;
      --binary)      binary=$2; shift 2 ;;
      --type)        type=$2; shift 2 ;;
      --server-type) server_type=$2; shift 2 ;;
      --node-id)     node_id=$2; shift 2 ;;
      --panel-url|--panel) url=$2; shift 2 ;;
      --panel-key|--token) key=$2; shift 2 ;;
      # The flags of the install command Xboard shows when a machine is added.
      --mode)        mode=$2; shift 2 ;;
      --machine-id)  machine_id=$2; shift 2 ;;
      # The flags of the one-click command V2board shows for a v2node node.
      --api-host)    url=$2; v2node=1; shift 2 ;;
      --api-key)     key=$2; v2node=1; shift 2 ;;
      --license)     license=$2; shift 2 ;;
      *=*)           extra+=("$1"); shift ;;
      *) die "unknown option $1" ;;
    esac
  done
  [ -z "$machine_id" ] || mode=machine
  [ -z "$v2node" ] || [ -n "$type_set" ] || type=v2node
  if [ ! -f "$CONF" ] && [ "$mode" = machine ]; then
    [ -n "$machine_id" ] && [ -n "$url" ] && [ -n "$key" ] \
      || die "machine mode needs --machine-id, --panel and --token (the command Xboard shows when the machine is added)"
  elif [ ! -f "$CONF" ] && [ "$type" = local ]; then
    # No panel: the protocol, port and users are settings on the command line.
    [ -n "$server_type" ] || die "--type local needs --server-type (socks, shadowsocks, trojan, ...)"
    printf '%s\n' "${extra[@]:-}" | grep -qi '^port=' || die "--type local needs port=NNNN"
    printf '%s\n' "${extra[@]:-}" | grep -qi '^users=' || die "--type local needs users=name:secret,name:secret"
  elif [ ! -f "$CONF" ]; then
    [ -n "$node_id" ] && [ -n "$url" ] && [ -n "$key" ] \
      || die "a first install needs --node-id, --panel-url and --panel-key (or V2board's --api-host, --node-id and --api-key)"
    # Xboard tells the node what protocol it is; other panels have to be told.
    [ -n "$server_type" ] || [ "$type" = xboard ] || [ "$type" = v2node ] || die "--server-type is required for $type"
  fi

  id kaze >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin kaze
  umask 077
  migrate
  if [ -n "$NAME" ] && [ -x "$BIN" ] && [ -z "$binary" ]; then
    echo "using the installed $("$BIN" -v) for instance $NAME"
  else
    install_binary "$binary"
  fi
  mkdir -p "$DIR"
  if [ ! -f "$CONF" ]; then
    {
      if [ "$mode" = machine ]; then
        # Xboard machine mode: the panel says which nodes this machine runs.
        echo "type=xboard"
        echo "webapi_url=$url"
        echo "machine_id=$machine_id"
        echo "machine_token=$key"
      elif [ "$type" = local ]; then
        echo "type=local"
        echo "server_type=$server_type"
      else
        echo "type=$type"
        [ -z "$server_type" ] || echo "server_type=$server_type"
        echo "node_id=$node_id"
        echo "webapi_url=$url"
        echo "webapi_key=$key"
      fi
      [ -z "$license" ] || echo "license_key=$license"
      for kv in "${extra[@]:-}"; do [ -z "$kv" ] || echo "$kv"; done
    } > "$CONF"
    echo "wrote $CONF"
  else
    echo "keeping the existing $CONF"
  fi
  chown -R kaze:kaze "$DIR"; chmod 700 "$DIR"; chmod 600 "$CONF"
  write_ctl
  write_unit

  local k="kaze${NAME:+ -n $NAME}"
  echo "checking the configuration against the panel"
  if ! sudo -u kaze "$BIN" -c "$CONF" -check; then
    echo
    echo "The check failed, so the service was not started. Fix $CONF (or: $k config key=value), then: $k restart"
    systemctl enable "$SVC" >/dev/null 2>&1 || true
    exit 1
  fi
  systemctl enable --now "$SVC"
  sleep 2
  systemctl --no-pager --lines=8 status "$SVC" || true
  echo
  echo "done. Type $k for the menu, or: $k status | $k log | $k config key=value | $k restart"
}

latest_tag() {
  curl -fsSI --max-time 30 "$RELEASES/releases/latest" 2>/dev/null | tr -d '\r' | sed -n 's#^[Ll]ocation: .*/tag/##p' || true
}

# running lists the instances that are up: the ones an update restarts.
# A stopped or disabled one is the operator's choice and stays as it is.
running() { local s; for s in $(instances); do ! systemctl is-active --quiet "$s" || echo "$s"; done; }

# healthy reports whether every named instance is running and has not
# crashed since the start we made: a restart resets NRestarts to zero, so
# a crash loop within the window shows as a count above it.
healthy() { # svc...
  sleep 8
  local s
  for s in "$@"; do
    systemctl is-active --quiet "$s" && [ "$(systemctl show -p NRestarts --value "$s")" = 0 ] || return 1
  done
}

restart_all() { local s; for s in "$@"; do systemctl restart "$s" || true; done; }

# migrate moves a program installed by a release before v0.4.3 from
# /usr/local/bin/kaze, where the control script now goes, to its own
# directory, and points the service there. The running process is not
# touched; it picks up the new path at its next restart.
migrate() {
  if [ -f "$OLD_BIN" ] && head -c 4 "$OLD_BIN" | grep -q ELF; then
    mkdir -p "$(dirname "$BIN")"
    if [ -x "$BIN" ]; then mv "$OLD_BIN" "$BIN.prev"; else mv "$OLD_BIN" "$BIN"; fi
    [ ! -f "$OLD_BIN.prev" ] || mv "$OLD_BIN.prev" "$BIN.prev"
    if grep -q "ExecStart=$OLD_BIN " /etc/systemd/system/kaze.service 2>/dev/null; then
      local keep=$NAME; set_name ""; write_unit; set_name "$keep"
    fi
    echo "moved the program to $BIN; \"kaze\" now opens the menu"
  fi
}

cmd_update() {
  migrate
  [ -x "$BIN" ] || die "kaze is not installed"
  shift
  local local_bin="" if_newer=""
  for a in "$@"; do
    case "$a" in
      --if-newer) if_newer=1 ;;
      *) local_bin=$a ;;
    esac
  done
  if [ -n "$if_newer" ] && [ -z "$local_bin" ]; then
    local cur latest
    cur=$("$BIN" -v | awk '{print $2}'); latest=$(latest_tag)
    [ -n "$latest" ] || die "cannot learn the latest version"
    if [ "$cur" = "$latest" ]; then echo "already the latest ($cur)"; return 0; fi
  fi
  local up; up=$(running)
  install_binary "$local_bin" # keeps the version being replaced as $BIN.prev
  write_ctl
  # A new release may need another permission, such as the one port hopping
  # needs: every instance's unit is rewritten.
  local s n
  for s in $(instances); do n=${s#kaze}; set_name "${n#-}"; write_unit; done
  set_name ""
  # shellcheck disable=SC2086
  restart_all $up
  # shellcheck disable=SC2086
  if healthy $up; then
    echo "updated to $("$BIN" -v | awk '{print $2}') and running; the previous version is kept (kaze rollback)"
  else
    echo "the new version did not stay up; going back to the previous one" >&2
    for s in $up; do journalctl -u "$s" -n 15 --no-pager -o cat >&2 || true; done
    mv "$BIN.prev" "$BIN"
    # shellcheck disable=SC2086
    restart_all $up
    die "rolled back to $("$BIN" -v | awk '{print $2}')"
  fi
}

cmd_rollback() {
  migrate
  [ -x "$BIN.prev" ] || die "no previous version is kept; it is kept from the next update on"
  local cur prev
  cur=$("$BIN" -v | awk '{print $2}'); prev=$("$BIN.prev" -v | awk '{print $2}')
  mv "$BIN" "$BIN.next" && mv "$BIN.prev" "$BIN" && mv "$BIN.next" "$BIN.prev"
  # shellcheck disable=SC2046
  restart_all $(running)
  echo "rolled back from $cur to $prev (run kaze rollback again to return to $cur)"
}

cmd_uninstall() {
  if [ "${1:-}" = --name ]; then
    # One instance goes; the program and the others stay.
    set_name "${2:-}"
    [ -n "$NAME" ] || die "--name needs the instance's name"
    [ -f "$UNIT" ] || die "no instance named $NAME"
    systemctl disable --now "$SVC" 2>/dev/null || true
    rm -f "$UNIT"
    systemctl daemon-reload
    echo "removed instance $NAME. Its configuration is kept in $DIR; delete it with: rm -rf $DIR"
    return 0
  fi
  local s
  for s in $(instances); do systemctl disable --now "$s" 2>/dev/null || true; rm -f "/etc/systemd/system/$s.service"; done
  systemctl disable --now kaze-update.timer 2>/dev/null || true
  rm -f "$BIN" "$BIN.prev" "$LOCAL_SCRIPT" "$CTL" "$CTL_ALIAS" "$TIMER" /etc/systemd/system/kaze-update.service
  rmdir "$(dirname "$BIN")" 2>/dev/null || true
  systemctl daemon-reload
  echo "removed the program and the services. The configuration is kept in /etc/kaze (and /etc/kaze-NAME for other instances);"
  echo "delete it, and the kaze user, with: rm -rf /etc/kaze /etc/kaze-* && userdel kaze"
}

case "${1:-}" in
  install)   shift; cmd_install "$@" ;;
  --*)       cmd_install "$@" ;;  # Xboard's machine command and V2board's v2node command pass options only
  update)    cmd_update "$@" ;;
  rollback)  cmd_rollback ;;
  uninstall) shift; cmd_uninstall "$@" ;;
  *) echo "usage: install.sh install [options] | update [--if-newer] | rollback | uninstall [--name NAME]"; echo "see https://docs.kazecore.dev/quickstart/install/"; exit 1 ;;
esac
