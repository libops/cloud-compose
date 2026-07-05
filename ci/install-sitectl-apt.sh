#!/usr/bin/env bash

set -euo pipefail

packages=("$@")
if [ "${#packages[@]}" -eq 0 ]; then
  packages=(sitectl-isle sitectl-wp)
fi

sudo apt-get update -qq
sudo apt-get install -y ca-certificates curl gnupg openssh-client jq

curl -fsSL https://packages.libops.io/sitectl/sitectl-archive-keyring.asc |
  sudo gpg --dearmor -o /usr/share/keyrings/sitectl-archive-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/sitectl-archive-keyring.gpg] https://packages.libops.io/sitectl ./" |
  sudo tee /etc/apt/sources.list.d/sitectl.list >/dev/null

sudo apt-get update -qq
sudo apt-get install -y "${packages[@]}"
