# Compose policy. Local development is where bad defaults get established and then
# copied into production manifests, so the same rules are enforced here.
package main

import rego.v1

service_names contains name if {
	some name, _ in input.services
}

# ------------------------------------------------------------------- privileges

deny contains msg if {
	some name, svc in input.services
	svc.privileged == true
	msg := sprintf("service '%s' runs privileged", [name])
}

deny contains msg if {
	some name, svc in input.services
	svc.network_mode == "host"
	msg := sprintf("service '%s' uses host networking, bypassing network isolation", [name])
}

deny contains msg if {
	some name, svc in input.services
	some cap in svc.cap_add
	cap in {"SYS_ADMIN", "ALL", "NET_ADMIN"}
	msg := sprintf("service '%s' adds dangerous capability %s", [name, cap])
}

# ------------------------------------------------------------------- operability

warn contains msg if {
	some name, svc in input.services
	not svc.healthcheck
	not svc.build # built services carry HEALTHCHECK in their Dockerfile
	msg := sprintf("service '%s' has no healthcheck", [name])
}

warn contains msg if {
	some name, svc in input.services
	not svc.restart
	msg := sprintf("service '%s' has no restart policy", [name])
}

# --------------------------------------------------------------------- secrets

# Interpolated values (${DB_PASSWORD}) are fine; literals are committed credentials.
deny contains msg if {
	some name, svc in input.services
	some key, value in svc.environment
	lower_key := lower(key)
	some pattern in ["password", "secret", "api_key", "apikey", "token"]
	contains(lower_key, pattern)
	is_string(value)
	not contains(value, "${")
	not value == ""
	msg := sprintf("service '%s' hardcodes %s — use ${VAR} interpolation or a secret", [name, key])
}

# Mounting the docker socket hands the container root on the host.
deny contains msg if {
	some name, svc in input.services
	some vol in svc.volumes
	is_string(vol)
	contains(vol, "/var/run/docker.sock")
	msg := sprintf("service '%s' mounts the docker socket — that is host root access", [name])
}
