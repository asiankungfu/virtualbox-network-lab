# 構築ガイド ― VirtualBox 仮想ネットワーク環境を一から作る

このドキュメントは、**インフラ初心者でもゼロからこの環境を再現できる**ことを目的にした手順書です。読みながら同じファイルを作っていけば、PC の中に「Web サーバー + DB サーバー」の 2 台構成ネットワークが完成します。コピペで動くよう、各ファイルの全文と「なぜそう書くのか」をすべて載せています。

---

## 0. 完成するもの（ゴール）

`vagrant up` というコマンドを 1 回打つだけで、以下が自動でできあがります。

- **web-server**（IP: 192.168.56.10）… Nginx が動く Web サーバー
- **db-server**（IP: 192.168.56.11）… MariaDB が動くデータベースサーバー
- 2 台はプライベートネットワークでつながり、ブラウザから Web に、Web から DB に接続できる

```
ブラウザ(localhost:8080) ──→ web-server:80 (Nginx) ──→ db-server:3306 (MariaDB)
                ポート転送            内部ネットワーク 192.168.56.0/24
```

ポイントは、これらの構成を**すべてファイル（コード）として書いておく**こと。これを **IaC（Infrastructure as Code）** と呼びます。手作業を排除でき、誰でも・何度でも同じ環境を再現できます。

---

## 1. 前提となる用語（最初に押さえる 3 つ）

| 用語 | ひとことで言うと | このプロジェクトでの役割 |
|---|---|---|
| **VirtualBox** | PC の中に仮想 PC（VM）を作るソフト | VM の実体を動かすエンジン |
| **Vagrant** | 「VM をどう作るか」を設定ファイルに書くと自動構築してくれる司令塔 | `Vagrantfile` を読んで VirtualBox を操作 |
| **プロビジョニング** | 作った VM の中に、ソフトを入れて設定する作業 | `provision/*.sh`（シェルスクリプト）が担当 |

もう 1 つ重要なのが **冪等性（べきとうせい / idempotency）**。「**何度実行しても同じ結果になる**」という性質です。たとえば「Nginx を入れる」処理は、すでに入っていればスキップする ── こう書いておくと、再実行で壊れません。

---

## 2. 必要なソフトをインストールする

作業 PC に以下の 2 つを入れます（無料）。

1. **VirtualBox** … <https://www.virtualbox.org/> からダウンロードしてインストール
2. **Vagrant** … <https://developer.hashicorp.com/vagrant/install> からインストール

インストールできたか確認:

```bash
vboxmanage --version   # VirtualBox のバージョンが出れば OK
vagrant --version      # Vagrant のバージョンが出れば OK
```

> **⚠ Apple Silicon（M1/M2/M3 の Mac）の注意**
> VirtualBox は本来 Intel（x86）向けの技術です。Apple Silicon では動作が限定的・不安定なことがあります。うまくいかない場合は、Intel Mac か Windows、あるいは UTM / Parallels / QEMU などの代替を検討してください。学習目的なら「仕組みを理解する」ことが主目的なので、まずこのガイド通りに作ってみるのがおすすめです。

---

## 3. プロジェクト全体の構成

最終的にこういうフォルダ構成になります。先に全体像を把握しておきましょう。

```
virtualbox-network-lab/
├── Vagrantfile            # VM の設計図（何台・IP・メモリ・実行スクリプト）
├── provision/
│   ├── common.sh          # 全 VM 共通の下準備（パッケージ更新）
│   ├── web.sh             # Nginx の導入・設定
│   └── db.sh              # MariaDB の導入・初期化
├── config/
│   ├── nginx.conf         # Nginx の設定ファイル
│   └── mariadb.cnf        # MariaDB の設定ファイル
├── .env.example           # パスワード設定の雛形
├── .gitignore             # Git に上げないファイルの指定
├── LICENSE                # ライセンス（MIT）
├── README.md              # リポジトリの説明
└── .github/workflows/
    └── ci.yml             # GitHub Actions（自動チェック）
```

まずフォルダを作ります:

```bash
mkdir -p virtualbox-network-lab/{provision,config,.github/workflows}
cd virtualbox-network-lab
```

---

## 4. 各ファイルを作る

ここからは、上から順にファイルを作っていきます。**全文をコピペ**して、解説を読んで理解する流れです。

### 4-1. Vagrantfile（設計図）

このプロジェクトの心臓部です。Ruby という言語で書かれていますが、設定を書くだけなので Ruby を知らなくても大丈夫です。

```ruby
# -*- mode: ruby -*-
# vi: set ft=ruby :

# .env があれば読み込む（パスワードなどの秘密情報。Git には上げない）
env_file = File.expand_path(".env", __dir__)
if File.exist?(env_file)
  File.readlines(env_file).each do |line|
    line = line.strip
    next if line.empty? || line.start_with?("#")
    key, _, value = line.partition("=")
    ENV[key.strip] ||= value.strip
  end
end

# ===== 設定値はここで一括管理（変えたいときはここだけ直す） =====
BOX_NAME = "ubuntu/jammy64"   # ベースになる OS イメージ (Ubuntu 22.04)
WEB_IP   = "192.168.56.10"    # Web サーバーの IP
DB_IP    = "192.168.56.11"    # DB サーバーの IP
WEB_MEM  = 1024               # Web のメモリ(MB)
DB_MEM   = 1024               # DB のメモリ(MB)
VM_CPUS  = 1                  # CPU コア数

DB_ROOT_PASS = ENV.fetch("DB_ROOT_PASS", "changeme_root_pass")
DB_APP_PASS  = ENV.fetch("DB_APP_PASS",  "app_password")

Vagrant.configure("2") do |config|
  config.vm.box = BOX_NAME

  # --- VM その1: web-server ---
  config.vm.define "web-server" do |web|
    web.vm.hostname = "web-server"
    web.vm.network "private_network", ip: WEB_IP          # 内部ネットワーク
    web.vm.network "forwarded_port", guest: 80, host: 8080, auto_correct: true  # ポート転送
    web.vm.provider "virtualbox" do |vb|
      vb.name = "web-server"; vb.memory = WEB_MEM; vb.cpus = VM_CPUS
    end
    web.vm.provision "shell", path: "provision/common.sh"
    web.vm.provision "shell", path: "provision/web.sh", args: [DB_IP]
  end

  # --- VM その2: db-server ---
  config.vm.define "db-server" do |db|
    db.vm.hostname = "db-server"
    db.vm.network "private_network", ip: DB_IP
    db.vm.provider "virtualbox" do |vb|
      vb.name = "db-server"; vb.memory = DB_MEM; vb.cpus = VM_CPUS
    end
    db.vm.provision "shell", path: "provision/common.sh"
    db.vm.provision "shell", path: "provision/db.sh",
      env: { "DB_ROOT_PASS" => DB_ROOT_PASS, "DB_APP_PASS" => DB_APP_PASS },
      args: [WEB_IP]
  end
end
```

**読み解き方:**
- 冒頭で設定値を変数にまとめている → IP を変えたいときはここ 1 か所だけ直せばよい（保守性）。
- `private_network` … 2 台だけがつながる内部ネットワークを作る。
- `forwarded_port` … 自分の PC の 8080 番を、web-server の 80 番につなぐ橋渡し。だからブラウザで `localhost:8080` が見える。
- `provision "shell"` … VM 起動後に実行するスクリプトの指定。`common.sh` → 個別スクリプトの順で走る。
- パスワードは直接書かず `.env` や環境変数から取る（セキュリティ）。

### 4-2. provision/common.sh（共通の下準備）

```bash
#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update -y      # パッケージ一覧を更新
apt-get upgrade -y     # 既存パッケージを更新
apt-get install -y curl wget git   # 共通ツール
```

`set -euo pipefail` は「エラーが出たら止まる / 未定義の変数を使ったら止まる」というおまじない。スクリプトを安全にします。`apt-get` は導入済みのものは自動でスキップするので、これだけで冪等です。

### 4-3. provision/web.sh（Nginx を入れる）

```bash
#!/usr/bin/env bash
set -euo pipefail
DB_IP="${1:-192.168.56.11}"
CONFIG_SRC="/vagrant/config/nginx.conf"
NGINX_SITE="/etc/nginx/sites-available/default"
export DEBIAN_FRONTEND=noninteractive

# 1. Nginx を入れる（入っていればスキップ＝冪等）
if which nginx >/dev/null 2>&1; then
  echo "Nginx は導入済み"
else
  apt-get update -y && apt-get install -y nginx
fi

# 1.5 DB 接続確認用に mysql クライアントも入れる
which mysql >/dev/null 2>&1 || apt-get install -y mariadb-client

# 2. 設定ファイルを配置（中身が変わっていれば上書き）
if [ -f "${CONFIG_SRC}" ] && ! diff -q "${CONFIG_SRC}" "${NGINX_SITE}" >/dev/null 2>&1; then
  cp "${CONFIG_SRC}" "${NGINX_SITE}"
fi

# 2.5 動作確認用トップページを置く
mkdir -p /var/www/html
echo "<h1>web-server running</h1><p>DB: ${DB_IP}</p>" > /var/www/html/index.html

# 3. 設定を有効化
ln -sf "${NGINX_SITE}" /etc/nginx/sites-enabled/default
nginx -t                       # 設定の文法チェック
systemctl enable nginx
systemctl restart nginx

# 5. ファイアウォール（SSH を先に許可してから 80 を開けて有効化）
if command -v ufw >/dev/null 2>&1; then
  ufw allow OpenSSH >/dev/null 2>&1 || true
  ufw allow 80/tcp  >/dev/null 2>&1 || true
  ufw status | grep -q "Status: active" || ufw --force enable
fi
```

ポイントは `/vagrant/` という特別なフォルダ。Vagrant は**プロジェクトフォルダを VM 内の `/vagrant` に自動共有**します。だから `config/nginx.conf` を VM 側から `/vagrant/config/nginx.conf` として読めます。UFW では **SSH を必ず先に許可**します（これを忘れて有効化すると、自分が VM に入れなくなるため）。

### 4-4. provision/db.sh（MariaDB を入れる）

```bash
#!/usr/bin/env bash
set -euo pipefail
WEB_IP="${1:-192.168.56.10}"
DB_ROOT_PASS="${DB_ROOT_PASS:-changeme_root_pass}"
APP_USER="appuser"; APP_PASS="${DB_APP_PASS:-app_password}"; APP_DB="appdb"
CONFIG_SRC="/vagrant/config/mariadb.cnf"
CONFIG_DST="/etc/mysql/mariadb.conf.d/99-custom.cnf"
export DEBIAN_FRONTEND=noninteractive

# 1. MariaDB を入れる（冪等）
if which mysqld >/dev/null 2>&1 || which mariadbd >/dev/null 2>&1; then
  echo "MariaDB は導入済み"
else
  apt-get update -y && apt-get install -y mariadb-server mariadb-client
fi

# 設定ファイルを配置（外部接続許可など）
if [ -f "${CONFIG_SRC}" ] && ! diff -q "${CONFIG_SRC}" "${CONFIG_DST}" >/dev/null 2>&1; then
  cp "${CONFIG_SRC}" "${CONFIG_DST}"
fi

systemctl enable mariadb
systemctl restart mariadb
for i in $(seq 1 30); do mysqladmin ping >/dev/null 2>&1 && break; sleep 1; done

# root の接続方法を自動判定（初回はパスワード無し、2回目以降は有り）
if mysql -u root -e "SELECT 1" >/dev/null 2>&1; then
  ROOT_LOGIN="mysql -u root"
else
  ROOT_LOGIN="mysql -u root -p${DB_ROOT_PASS}"
fi

# root パスワード設定＋不要ユーザー削除（mysql_secure_installation 代替）
${ROOT_LOGIN} <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASS}';
DELETE FROM mysql.user WHERE User='';
DROP DATABASE IF EXISTS test;
FLUSH PRIVILEGES;
SQL

# アプリ用 DB とユーザーを作成（IF NOT EXISTS で冪等）
mysql -u root -p"${DB_ROOT_PASS}" <<SQL
CREATE DATABASE IF NOT EXISTS \`${APP_DB}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${APP_USER}'@'192.168.56.%' IDENTIFIED BY '${APP_PASS}';
GRANT ALL PRIVILEGES ON \`${APP_DB}\`.* TO '${APP_USER}'@'192.168.56.%';
FLUSH PRIVILEGES;
SQL

# 7. ファイアウォール: 3306 は web-server からのみ許可
if command -v ufw >/dev/null 2>&1; then
  ufw allow OpenSSH >/dev/null 2>&1 || true
  ufw allow from "${WEB_IP}" to any port 3306 proto tcp >/dev/null 2>&1 || true
  ufw status | grep -q "Status: active" || ufw --force enable
fi
```

DB は少し複雑ですが、やっていることは「インストール → 設定配置 → 起動 → root パスワード設定 → アプリ用ユーザー作成 → 3306 番を web からだけ開ける」の流れです。`IF NOT EXISTS` を使うことで、再実行してもエラーにならない（冪等）ようにしています。

### 4-5. config/nginx.conf

```nginx
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    root /var/www/html;
    index index.html index.htm;
    access_log /var/log/nginx/access.log;
    error_log  /var/log/nginx/error.log;
    location / {
        try_files $uri $uri/ =404;
    }
}
```

80 番ポートで待ち受け、`/var/www/html` の中身を返す、という基本設定です。

### 4-6. config/mariadb.cnf

```ini
[mysqld]
bind-address            = 0.0.0.0
character-set-server    = utf8mb4
collation-server        = utf8mb4_unicode_ci
max_connections         = 100
innodb_buffer_pool_size = 256M
```

`bind-address = 0.0.0.0` は「外部からの接続も受け付ける」設定。ただし無制限ではなく、実際のアクセス制限は前述の UFW（3306 は web-server だけ）で行います。「設定で開けて、ファイアウォールで絞る」という二段構えです。

### 4-7. 公開・補助ファイル

**.gitignore**（Git に上げないものを指定）:

```gitignore
.vagrant/
*.log
.env
*.swp
*.swo
.DS_Store
```

`.env`（パスワードを書くファイル）を除外しているのが重要。秘密情報を GitHub に上げない、という基本です。

**.env.example**（パスワード雛形。これは上げて OK）:

```bash
DB_ROOT_PASS=change_this_strong_password
DB_APP_PASS=change_this_app_password
```

使うときは `cp .env.example .env` してから中身を自分のパスワードに書き換えます。

**LICENSE** … MIT ライセンス本文を入れます（[choosealicense.com](https://choosealicense.com/licenses/mit/) からコピー可）。

---

## 5. 起動と動作確認

```bash
# パスワードを設定（.env を使う方法）
cp .env.example .env        # 中身を好きなパスワードに編集

# 環境を構築（初回は OS イメージのダウンロードで数分かかる）
vagrant up
```

確認手順:

| やること | コマンド | 期待結果 |
|---|---|---|
| VM の状態確認 | `vagrant status` | 2 台とも `running` |
| Web 表示確認 | ブラウザで `http://localhost:8080` | ページが表示される |
| Web→DB 接続確認 | `vagrant ssh web-server -c "mysql -h 192.168.56.11 -u appuser -p"` | DB に接続できる |
| 冪等性の確認 | `vagrant provision` | エラーなく再実行できる |

よく使う運用コマンド: `vagrant halt`（停止） / `vagrant reload`（再起動） / `vagrant destroy -f`（破棄）。

---

## 6. GitHub に公開する

```bash
git init -b main
git add .
git commit -m "feat: VirtualBox 2VM network lab (Nginx + MariaDB)"
git remote add origin https://github.com/<あなたのユーザー名>/virtualbox-network-lab.git
git push -u origin main
```

事前に GitHub 上で**空のリポジトリ**（README なし）を作っておきます。認証はユーザー名 + Personal Access Token（または `gh auth login`）で行います。コミットメッセージは `feat`（機能追加）/ `fix`（修正）/ `docs`（文書）/ `chore`（雑務）の接頭辞をつけると、後から履歴が読みやすくなります。

---

## 7. GitHub Actions で自動チェック（CI）

`.github/workflows/ci.yml` を置くと、**push のたびに GitHub のサーバー上で自動テスト**が走ります。

```yaml
name: CI
on:
  push:
    branches: [ main ]
  pull_request:
    branches: [ main ]

jobs:
  shellcheck:                       # ① シェルスクリプトの静的解析
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: ludeeus/action-shellcheck@master
        with:
          scandir: ./provision
          severity: error

  vagrantfile:                      # ② Vagrantfile の文法チェック
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: '3.2'
      - run: ruby -c Vagrantfile

  nginx-config:                     # ③ Nginx 設定の妥当性検証
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: sudo apt-get update && sudo apt-get install -y nginx
      - run: |
          sudo cp config/nginx.conf /etc/nginx/sites-available/default
          sudo ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
          sudo nginx -t

  structure:                        # ④ 必須ファイルの存在確認
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: |
          for f in Vagrantfile provision/common.sh provision/web.sh provision/db.sh \
                   config/nginx.conf config/mariadb.cnf .gitignore README.md LICENSE; do
            test -f "$f" && echo "OK: $f" || { echo "MISSING: $f"; exit 1; }
          done
```

**仕組み:** `on:` で「いつ動かすか」、`jobs:` で「何をするか」を定義します。各ジョブは GitHub が用意するまっさらな Ubuntu 上で動き、`actions/checkout@v4` でコードを取得してから検査します。全部成功すると README の **CI バッジが緑（passing）** になります。

> **なぜ `vagrant up` は CI でやらないのか？**
> GitHub の標準ランナーは VirtualBox による仮想化（仮想化の入れ子）に対応していません。そのため CI では「コードが正しいか」の検証に絞ります。これは実務でもよくある割り切りです。

---

## 8. 困ったときは（トラブルシューティング）

| 症状 | 対処 |
|---|---|
| `vagrant up` でネットワークエラー | VirtualBox の `/etc/vbox/networks.conf` に `192.168.56.0/24` を許可する記述を追加 |
| `localhost:8080` が開けない | `vagrant ssh web-server -c "systemctl status nginx"` で Nginx の状態を確認 |
| Web から DB につながらない | DB 側の `bind-address=0.0.0.0`、UFW の 3306 許可、ユーザー権限を確認 |
| Apple Silicon で起動しない | VirtualBox は x86 前提。Intel 環境か代替仮想化を使用 |
| やり直したい | `vagrant destroy -f` で消してから `vagrant up` |

---

## 9. 用語ミニ辞典

- **VM（仮想マシン）**: PC の中に作るもう 1 台の仮想的なコンピュータ。
- **プロビジョニング**: VM の中にソフトを入れて設定する作業の自動化。
- **冪等性**: 何度実行しても同じ結果になる性質。再実行で壊れない。
- **IaC**: インフラ構成をコードで管理する考え方。再現性・共有性が上がる。
- **CI（継続的インテグレーション）**: コード変更のたびに自動でテスト・検証する仕組み。
- **ポートフォワード**: あるポートへの通信を別のマシン/ポートへ転送すること。

---

これで、誰でもこの環境を一から再現できます。詰まったら各章のコマンドと期待結果を見比べて、どこで止まったかを切り分けてください。
