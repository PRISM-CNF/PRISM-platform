[Unit]
Description=NSM-OVS host-managed PCM core L1 exporter
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=@PCM_L1_WORKDIR@
Environment=TZ=@TZ@
ExecStart=/usr/bin/python3 @PCM_L1_SCRIPT_PATH@ --env-file @PCM_L1_ENV_FILE@
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
