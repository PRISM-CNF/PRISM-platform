[global]
print_configs = false
hostname = "@HOSTNAME@"
omit_hostname = false
precision = "ms"
interval = 15
providers = ["local"]
disable_usage_report = true

[log]
file_name = "stdout"
max_size = 100
max_age = 1
max_backups = 1
local_time = true
compress = false

[writer_opt]
batch = 8000
chan_size = 50000

[http]
enable = true
address = "@CATEGRAF_HTTP_ADDRESS@"
print_access = false
run_mode = "release"
ignore_hostname = false
agent_host_tag = ""
ignore_global_labels = false

[heartbeat]
enable = false

[[writers]]
url = "@N9E_REMOTE_WRITE_URL@"
timeout = 5000
dial_timeout = 2500
max_idle_conns_per_host = 32
