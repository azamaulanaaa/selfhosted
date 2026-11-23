# Consul server configuration. Committed desired state.
# The wizard renders this file to config/consul/consul.hcl.
# Local wizard answers live in config/consul/local.hcl.
# The wizard writes the bootstrap server count to config/consul/bootstrap.hcl.
# Secrets live in config/consul/secrets/agent.hcl.
server = true
datacenter = "dc1"
data_dir = "/consul/data"
client_addr = "0.0.0.0"

acl {
  enabled = true
  default_policy = "deny"
  enable_token_persistence = true
}
