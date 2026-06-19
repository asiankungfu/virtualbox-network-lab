#!/usr/bin/env bash
#
# 3.2.2 web.sh - Nginx プロビジョニングスクリプト
# 何度実行しても同じ結果になるよう冪等性を確保する。
#
# 引数 $1: db-server の IP（接続確認用に保持。本スクリプトでは未使用だが拡張用）
#
set -euo pipefail

DB_IP="${1:-192.168.56.11}"
CONFIG_SRC="/vagrant/config/nginx.conf"
NGINX_SITE="/etc/nginx/sites-available/default"
WEB_ROOT="/var/www/html"

export DEBIAN_FRONTEND=noninteractive

# ---- 1. Nginx インストール（存在確認後スキップ） ----
if which nginx >/dev/null 2>&1; then
  echo "==> [web] Nginx は既にインストール済み。スキップ"
else
  echo "==> [web] Nginx をインストール"
  apt-get update -y
  apt-get install -y nginx
fi

# ---- 1.5 MySQL クライアント（FR-07: db-server への接続確認に必要） ----
if which mysql >/dev/null 2>&1; then
  echo "==> [web] mysql クライアントは既に導入済み。スキップ"
else
  echo "==> [web] mariadb-client をインストール（DB 接続確認用）"
  apt-get install -y mariadb-client
fi

# ---- 2. 設定ファイルを config/nginx.conf で上書き（差分時のみ） ----
if [ -f "${CONFIG_SRC}" ]; then
  if ! diff -q "${CONFIG_SRC}" "${NGINX_SITE}" >/dev/null 2>&1; then
    echo "==> [web] nginx 設定を更新 (${NGINX_SITE})"
    cp "${CONFIG_SRC}" "${NGINX_SITE}"
  else
    echo "==> [web] nginx 設定に変更なし。スキップ"
  fi
else
  echo "==> [web] WARNING: ${CONFIG_SRC} が見つかりません。デフォルト設定を使用"
fi

# ---- 2.5 動作確認用のトップページを配置（冪等: 常に上書き） ----
echo "==> [web] ドキュメントルートにトップページを配置"
mkdir -p "${WEB_ROOT}"
cat > "${WEB_ROOT}/index.html" <<HTML
<!DOCTYPE html>
<html lang="ja">
<head>
  <meta charset="UTF-8">
  <title>virtualbox-network-lab | web-server</title>
  <style>
    body { font-family: sans-serif; max-width: 640px; margin: 60px auto; line-height: 1.7; }
    code { background:#f4f4f4; padding:2px 6px; border-radius:4px; }
    .ok { color:#2e7d32; font-weight:bold; }
  </style>
</head>
<body>
  <h1>web-server <span class="ok">running</span></h1>
  <p>Nginx は正常に起動しています。(VirtualBox 仮想ネットワーク環境)</p>
  <ul>
    <li>Web サーバー IP: <code>192.168.56.10</code></li>
    <li>DB サーバー IP: <code>${DB_IP}</code></li>
  </ul>
  <p>Provisioned by Vagrant &amp; shell scripts.</p>
</body>
</html>
HTML

# ---- 3. sites-enabled にシンボリックリンク作成（-f で上書き） ----
echo "==> [web] sites-enabled シンボリックリンクを作成"
ln -sf "${NGINX_SITE}" /etc/nginx/sites-enabled/default

# ---- 4. enable & restart（設定テスト後） ----
echo "==> [web] nginx -t で設定テスト"
nginx -t

if ! systemctl is-enabled nginx >/dev/null 2>&1; then
  echo "==> [web] nginx を enable"
  systemctl enable nginx
fi
echo "==> [web] nginx を restart"
systemctl restart nginx

# ---- 5. UFW で 80 番ポートを許可（SSH を先に許可してから有効化） ----
if command -v ufw >/dev/null 2>&1; then
  # SSH を先に許可しないと vagrant の接続が切れるため最優先で許可
  ufw allow OpenSSH >/dev/null 2>&1 || ufw allow 22/tcp >/dev/null 2>&1 || true
  if ! ufw status | grep -qw "80"; then
    echo "==> [web] UFW: 80/tcp を許可"
    ufw allow 80/tcp || true
  else
    echo "==> [web] UFW: 80 は既に許可済み"
  fi
  if ! ufw status | grep -q "Status: active"; then
    echo "==> [web] UFW を有効化"
    ufw --force enable || true
  fi
fi

echo "==> [web] 完了。http://localhost:8080 で確認できます"
