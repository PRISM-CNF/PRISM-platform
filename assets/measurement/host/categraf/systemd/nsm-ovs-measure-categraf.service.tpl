[Unit]
Description=NSM-OVS host-managed Categraf collector
After=network-online.target @N9E_SERVICE_NAME@.service
Wants=network-online.target
Requires=@N9E_SERVICE_NAME@.service

[Service]
Type=simple
User=@HOST_USER@
Group=@HOST_USER@
WorkingDirectory=@CATEGRAF_WORKDIR@
Environment=TZ=@TZ@
ExecStart=@CATEGRAF_EXEC_START@
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target

