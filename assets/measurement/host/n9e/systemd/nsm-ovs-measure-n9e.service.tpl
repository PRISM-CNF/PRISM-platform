[Unit]
Description=NSM-OVS host-managed Nightingale center
After=network-online.target @VM_SERVICE_NAME@.service
Wants=network-online.target
Requires=@VM_SERVICE_NAME@.service

[Service]
Type=simple
User=@HOST_USER@
Group=@HOST_USER@
WorkingDirectory=@N9E_WORKDIR@
Environment=TZ=@TZ@
ExecStart=@N9E_BIN@ -configs @N9E_CONFIG_DIR@
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
