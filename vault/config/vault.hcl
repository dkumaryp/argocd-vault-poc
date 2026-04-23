# HashiCorp Vault configuration - file storage backend (POC)
# For production: replace with Consul, Raft, or cloud storage backend

ui = true

api_addr = "http://0.0.0.0:8200"
cluster_addr = "http://0.0.0.0:8201"

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = true # Enable TLS for production!
}

storage "file" {
  path = "/vault/data"
}

# How long to retain audit logs
# audit {
#   file {
#     path = "/vault/logs/audit.log"
#   }
# }
