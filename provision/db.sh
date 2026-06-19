#!/usr/bin/env bash
#
# 3.2.3 db.sh - MariaDB プロビジョニングスクリプト
# 冪等に動作し、何度実行しても同じ状態に収束する。
#
# 引数 $1     : 接続を許可する web-server の IP
# 環境変数 DB_ROOT_PASS : MariaDB root パスワード（Vagrantfile から渡す）
#
set -euo pipefail

WEB_IP="${1:-192.168.56.10}"
DB_ROOT_PASS="${DB_ROOT_PASS:-changeme_root_pass}"
APP_USER="appuser"
APP_PASS="${DB_APP_PASS:-app_password}"
APP_DB="appdb"
CONFIG_SRC="/vagrant/config/mariadb.cnf"
CONFIG_DST="/etc/mysql/mariadb.conf.d/99-custom.cnf"

export DEBIAN_FRONTEND=noninteractive

# ---- 1. MariaDB インストール（存在確認後スキップ） ----
if which mysqld >/dev/null 2>&1 || which mariadbd >/dev/null 2>&1; then
  echo "==> [db] MariaDB は既にインストール済み。スキップ"
else
  echo "==> [db] MariaDB をインストール"
  apt-get update -y
  apt-get install -y mariadb-server mariadb-client
fi

# ---- 6. 設定ファイルを config/mariadb.cnf で配置（bind-address 等。差分時のみ） ----
if [ -f "${CONFIG_SRC}" ]; then
  if ! diff -q "${CONFIG_SRC}" "${CONFIG_DST}" >/dev/null 2>&1; then
    echo "==> [db] MariaDB 設定を更新 (${CONFIG_DST})"
    cp "${CONFIG_SRC}" "${CONFIG_DST}"
  else
    echo "==> [db] MariaDB 設定に変更なし。スキップ"
  fi
else
  echo "==> [db] WARNING: ${CONFIG_SRC} が見つかりません"
fi

# ---- 2. enable & start ----
if ! systemctl is-enabled mariadb >/dev/null 2>&1; then
  echo "==> [db] mariadb を enable"
  systemctl enable mariadb
fi
echo "==> [db] mariadb を restart（設定反映）"
systemctl restart mariadb

# サービスが起動するまで待機
for i in $(seq 1 30); do
  if mysqladmin ping >/dev/null 2>&1; then break; fi
  sleep 1
done

# ---- 3 & 4. root パスワード設定 (mysql_secure_installation 代替 / 冪等) ----
# 初回はソケット認証で接続でき、2 回目以降はパスワードが必要になる。
# どちらの状態でも収束するよう、接続できる方を自動判定する。
echo "==> [db] root 接続方法を判定"
if mysql -u root -e "SELECT 1" >/dev/null 2>&1; then
  ROOT_LOGIN="mysql -u root"                       # 未設定（ソケット認証）
elif mysql -u root -p"${DB_ROOT_PASS}" -e "SELECT 1" >/dev/null 2>&1; then
  ROOT_LOGIN="mysql -u root -p${DB_ROOT_PASS}"      # 既にパスワード設定済み
else
  echo "==> [db] ERROR: root で接続できません。手動確認が必要です" >&2
  exit 1
fi

echo "==> [db] root パスワード・セキュア設定を適用（冪等）"
${ROOT_LOGIN} <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASS}';
DELETE FROM mysql.user WHERE User='';
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db IN ('test','test\\_%');
FLUSH PRIVILEGES;
SQL

# 以降は設定済み root パスワードで実行
MYSQL="mysql -u root -p${DB_ROOT_PASS}"

# ---- 5. アプリ用 DB / ユーザー作成（IF NOT EXISTS で冪等） ----
echo "==> [db] アプリ用 DB (${APP_DB}) とユーザー (${APP_USER}) を作成"
${MYSQL} <<SQL
CREATE DATABASE IF NOT EXISTS \`${APP_DB}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
-- web-server からの接続を許可（FR-07）
CREATE USER IF NOT EXISTS '${APP_USER}'@'${WEB_IP}' IDENTIFIED BY '${APP_PASS}';
CREATE USER IF NOT EXISTS '${APP_USER}'@'192.168.56.%' IDENTIFIED BY '${APP_PASS}';
GRANT ALL PRIVILEGES ON \`${APP_DB}\`.* TO '${APP_USER}'@'${WEB_IP}';
GRANT ALL PRIVILEGES ON \`${APP_DB}\`.* TO '${APP_USER}'@'192.168.56.%';
FLUSH PRIVILEGES;
SQL

# ---- 7. UFW で 3306 番を web-server IP のみ許可 ----
if command -v ufw >/dev/null 2>&1; then
  # SSH を先に許可（vagrant の接続維持）
  ufw allow OpenSSH >/dev/null 2>&1 || ufw allow 22/tcp >/dev/null 2>&1 || true
  if ! ufw status | grep -q "3306.*${WEB_IP}"; then
    echo "==> [db] UFW: 3306/tcp を ${WEB_IP} のみ許可"
    ufw allow from "${WEB_IP}" to any port 3306 proto tcp || true
  else
    echo "==> [db] UFW: 3306 (${WEB_IP}) は既に許可済み"
  fi
  if ! ufw status | grep -q "Status: active"; then
    echo "==> [db] UFW を有効化（3306 は web-server からのみ到達可能）"
    ufw --force enable || true
  fi
fi

echo "==> [db] 完了。web-server から mysql -h 192.168.56.11 -u ${APP_USER} -p で接続可能"
