[global]
RunMode = "release"

[Log]
Dir = "logs"
Level = "INFO"
Output = "stdout"

[HTTP]
Host = "@N9E_HTTP_HOST@"
Port = @N9E_HTTP_PORT@
CertFile = ""
KeyFile = ""
PrintAccessLog = false
PProf = false
ExposeMetrics = true
ShutdownTimeout = 30
MaxContentLength = 67108864
ReadTimeout = 20
WriteTimeout = 40
IdleTimeout = 120

[HTTP.ShowCaptcha]
Enable = false

[HTTP.APIForAgent]
Enable = true

[HTTP.APIForService]
Enable = true

[HTTP.JWTAuth]
AccessExpired = 1500
RefreshExpired = 10080
RedisKeyPrefix = "/jwt/"

[HTTP.ProxyAuth]
Enable = false
HeaderUserNameKey = "X-User-Name"
DefaultRoles = ["Standard"]

[HTTP.RSA]
OpenRSA = false

[DB]
DSN = "@N9E_DB_DSN@"
Debug = false
DBType = "sqlite"
MaxLifetime = 7200
MaxOpenConns = 50
MaxIdleConns = 10

[Redis]
Address = "127.0.0.1:6379"
Password = ""
RedisType = "miniredis"

[Alert]
[Alert.Heartbeat]
IP = ""
Interval = 1000
EngineName = "default"

[Center]
MetricsYamlFile = "@N9E_METRICS_YAML@"
I18NHeaderKey = "X-Language"

[Center.AnonymousAccess]
PromQuerier = true
AlertDetail = true

[Pushgw]
LabelRewrite = true
ForceUseServerTS = false

[[Pushgw.Writers]]
Url = "@VM_REMOTE_WRITE_URL@"
BasicAuthUser = ""
BasicAuthPass = ""
Headers = ["X-From", "n9e-host"]
Timeout = 10000
DialTimeout = 3000
TLSHandshakeTimeout = 30000
ExpectContinueTimeout = 1000
IdleConnTimeout = 90000
KeepAlive = 30000
MaxConnsPerHost = 0
MaxIdleConns = 100
MaxIdleConnsPerHost = 100

[Ibex]
Enable = false
RPCListen = "127.0.0.1:20090"

