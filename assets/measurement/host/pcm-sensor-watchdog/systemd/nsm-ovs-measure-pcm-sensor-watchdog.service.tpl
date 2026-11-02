[Unit]
Description=NSM-OVS watchdog for pcm-sensor-server metrics endpoint
After=network-online.target pcm-sensor-server.service
Wants=network-online.target pcm-sensor-server.service

[Service]
Type=simple
Environment=TZ=@TZ@
EnvironmentFile=@PCM_WATCHDOG_ENV_FILE@
WorkingDirectory=@PCM_WATCHDOG_WORKDIR@
ExecStart=@PCM_WATCHDOG_SCRIPT_PATH@
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
