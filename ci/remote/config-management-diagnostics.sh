#!/usr/bin/env bash

set +e

echo "--- cloud-init status ---"
cloud-init status --long
echo "--- /var/log/cloud-init-output.log ---"
tail -n 300 /var/log/cloud-init-output.log
echo "--- bootstrap unit state ---"
systemctl show --no-pager \
    --property=ActiveState,SubState,Result,NRestarts,ExecMainCode,ExecMainStatus \
    cloud-compose-bootstrap.service
echo "--- cloud-compose unit state ---"
systemctl show --no-pager \
    --property=ActiveState,SubState,Result,NRestarts,ExecMainCode,ExecMainStatus \
    cloud-compose.service
echo "--- cloud-compose bootstrap journal ---"
journalctl -u cloud-compose-bootstrap.service --no-pager -n 300
echo "--- cloud-compose application journal ---"
journalctl -u cloud-compose.service --no-pager -n 300
echo "--- active bootstrap processes ---"
ps -eo pid,ppid,stat,etime,args --forest
echo "--- docker ps ---"
docker ps -a
echo "--- compose manifest ---"
cat /home/cloud-compose/compose-projects.json
