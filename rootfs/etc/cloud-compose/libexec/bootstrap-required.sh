#!/usr/bin/env bash
set -u
((EUID == 0)) || exit 255
sitectl=/etc/cloud-compose/bin/bootstrap-sitectl
[[ -x "$sitectl" && ! -L "$sitectl" ]] || sitectl=/home/cloud-compose/bin/sitectl
"$sitectl" host marker valid /var/lib/cloud-compose/bootstrap-complete >/dev/null 2>&1 && exit 1
exit 0
