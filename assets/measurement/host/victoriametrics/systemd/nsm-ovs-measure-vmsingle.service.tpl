[Unit]
Description=NSM-OVS host-managed VictoriaMetrics single-node
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=@HOST_USER@
Group=@HOST_USER@
WorkingDirectory=@VM_WORKDIR@
Environment=TZ=@TZ@
ExecStart=@VM_BIN@ -loggerTimezone @TZ@ -storageDataPath @VM_DATA_DIR@ -httpListenAddr @VM_LISTEN_ADDR@ -retentionPeriod @VM_RETENTION@
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target

