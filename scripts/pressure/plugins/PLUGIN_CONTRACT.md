# Pressure Plugin Contract

Each plugin directory under `scripts/pressure/plugins/<name>/` must provide:

1. `plugin.env`
2. `start.sh`
3. `stop.sh`
4. `README.md`

Required `plugin.env` keys:

- `PLUGIN_NAME`
- `PLUGIN_DIMENSION`
- `PLUGIN_VERSION`
- `PLUGIN_INTENSITY_GRID`
- `PLUGIN_INTENSITY_UNIT`
- `PLUGIN_INTENSITY_MAPPING`
- `PLUGIN_RECOMMENDED_CPUSET`
- `PLUGIN_SAFE_TO_RUN_ON_VNF_CORE`

`start.sh` contract:

- Accepts `--instance-id`, `--intensity`, `--cpuset`, `--duration`, `--pid-file`, `--log-file`
- May accept repeated `--param key=value`
- Must launch a background process and write its PID to `--pid-file`
- Must honor `--cpuset`
- Must implement `intensity=0` as a valid idle holder mode

`stop.sh` contract:

- Accepts `--pid-file`
- Must stop the background process started by `start.sh`
- Must be safe to call multiple times

