#!/usr/bin/env bash
set -e

RAW="${X_MILI_RAW_BASE:-https://raw.githubusercontent.com/Aimilibot/X-MILI/main}"

if [[ $EUID -ne 0 ]]; then
    echo "请使用 root 运行 / Please run as root" >&2
    exit 1
fi

bash <(curl -Ls "${RAW}/install.sh")
