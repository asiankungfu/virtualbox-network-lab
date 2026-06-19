#!/usr/bin/env bash
#
# 3.2.1 common.sh - 共通プロビジョニング処理
# 全 VM 共通のパッケージ更新と基本ツール導入。冪等に動作する。
#
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

echo "==> [common] パッケージリスト更新 (apt-get update)"
apt-get update -y

echo "==> [common] 既存パッケージ更新 (apt-get upgrade)"
apt-get upgrade -y

echo "==> [common] 共通ツールのインストール (curl wget git)"
# apt は既にインストール済みのパッケージをスキップするため冪等
apt-get install -y curl wget git

echo "==> [common] 完了"
