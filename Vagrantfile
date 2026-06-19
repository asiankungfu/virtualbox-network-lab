# -*- mode: ruby -*-
# vi: set ft=ruby :
#
# VirtualBox 仮想ネットワーク環境構築 - Vagrantfile
# Web サーバー (Nginx) + DB サーバー (MariaDB) の 2VM 構成
# 設計書 v1.0 準拠 / IaC (Infrastructure as Code)

# ============================================================
# .env 自動読込（存在すれば）。秘密情報はコミットしない（.gitignore 済）
#   cp .env.example .env してパスワードを設定してください。
# ============================================================
env_file = File.expand_path(".env", __dir__)
if File.exist?(env_file)
  File.readlines(env_file).each do |line|
    line = line.strip
    next if line.empty? || line.start_with?("#")
    key, _, value = line.partition("=")
    ENV[key.strip] ||= value.strip
  end
end

# ============================================================
# 3.1.1 設定値定義（冒頭で一括管理 / 非機能要件: 保守性）
# ============================================================
# 設計書 VM仕様(2.3)・変数定義(3.1.1)に準拠し Ubuntu 22.04 LTS を使用。
# FR では 24.04 表記のため、24.04 にしたい場合は下記を "ubuntu/noble64" に変更。
BOX_NAME = "ubuntu/jammy64"   # 使用 Vagrant Box (Ubuntu 22.04 LTS)

WEB_IP   = "192.168.56.10"    # Web サーバーのホストオンリー IP
DB_IP    = "192.168.56.11"    # DB サーバーのホストオンリー IP

WEB_MEM  = 1024               # Web サーバーメモリ (MB)
DB_MEM   = 1024               # DB サーバーメモリ (MB)
VM_CPUS  = 1                  # vCPU コア数

WEB_FWD_HOST  = 8080          # ホスト側ポート (ポートフォワード)
WEB_FWD_GUEST = 80            # ゲスト側ポート (HTTP)

# MariaDB パスワード（環境変数 or .env から取得 / 非機能要件: セキュリティ）
# 例: export DB_ROOT_PASS="your_password" もしくは .env に記載
DB_ROOT_PASS = ENV.fetch("DB_ROOT_PASS", "changeme_root_pass")
DB_APP_PASS  = ENV.fetch("DB_APP_PASS",  "app_password")

Vagrant.configure("2") do |config|
  # 共通設定 ----------------------------------------------------
  config.vm.box = BOX_NAME

  # SSH キーの自動挿入を有効化
  config.ssh.insert_key = true

  # ============================================================
  # VM1: web-server (Nginx)
  # ============================================================
  config.vm.define "web-server" do |web|
    web.vm.hostname = "web-server"

    # 2.1 ホストオンリーネットワーク (private_network / vboxnet0)
    web.vm.network "private_network", ip: WEB_IP

    # 3.1.2 ホスト→VM ポートフォワード (HTTP 確認用)
    web.vm.network "forwarded_port",
      guest: WEB_FWD_GUEST, host: WEB_FWD_HOST,
      auto_correct: true

    web.vm.provider "virtualbox" do |vb|
      vb.name   = "web-server"
      vb.memory = WEB_MEM
      vb.cpus   = VM_CPUS
    end

    # 3.2 プロビジョニング: 共通処理 → Web 構築
    web.vm.provision "shell", path: "provision/common.sh"
    web.vm.provision "shell", path: "provision/web.sh", args: [DB_IP]
  end

  # ============================================================
  # VM2: db-server (MariaDB)
  # ============================================================
  config.vm.define "db-server" do |db|
    db.vm.hostname = "db-server"

    # 2.1 ホストオンリーネットワーク
    db.vm.network "private_network", ip: DB_IP

    db.vm.provider "virtualbox" do |vb|
      vb.name   = "db-server"
      vb.memory = DB_MEM
      vb.cpus   = VM_CPUS
    end

    # 3.2 プロビジョニング: 共通処理 → DB 構築
    # 引数: root パスワード, 接続を許可する web-server IP
    db.vm.provision "shell", path: "provision/common.sh"
    db.vm.provision "shell",
      path: "provision/db.sh",
      env:  { "DB_ROOT_PASS" => DB_ROOT_PASS, "DB_APP_PASS" => DB_APP_PASS },
      args: [WEB_IP]
  end
end
