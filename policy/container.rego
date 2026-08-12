# Container build policy, enforced in CI by conftest.
#
# Every rule here exists because the violation is invisible in testing and expensive in
# production: an image that runs as root passes every functional test, and a floating
# base tag makes a build irreproducible the moment upstream moves.
package main

import rego.v1

# ------------------------------------------------------------------ base images

deny contains msg if {
	some i
	input[i].Cmd == "from"
	image := input[i].Value[0]
	endswith(image, ":latest")
	msg := sprintf("base image '%s' uses the floating :latest tag — pin a version", [image])
}

deny contains msg if {
	some i
	input[i].Cmd == "from"
	image := input[i].Value[0]
	not contains(image, ":")
	not contains(image, "$") # ARG-substituted tags are fine
	not image == "scratch"
	msg := sprintf("base image '%s' has no tag — pin a version", [image])
}

# ------------------------------------------------------------------- privileges

# The last USER wins. If it is absent, or resets to root, the container runs privileged.
deny contains msg if {
	users := [u | some i; input[i].Cmd == "user"; u := input[i].Value[0]]
	count(users) == 0
	msg := "no USER instruction — the container would run as root"
}

deny contains msg if {
	users := [u | some i; input[i].Cmd == "user"; u := input[i].Value[0]]
	count(users) > 0
	last := users[count(users) - 1]
	last in {"root", "0"}
	msg := "final USER is root — drop to an unprivileged user before CMD"
}

# ------------------------------------------------------------------- operability

warn contains msg if {
	healthchecks := [h | some i; input[i].Cmd == "healthcheck"; h := input[i]]
	count(healthchecks) == 0
	msg := "no HEALTHCHECK — the orchestrator cannot tell a hung container from a healthy one"
}

# --------------------------------------------------------------------- hygiene

deny contains msg if {
	some i
	input[i].Cmd == "run"
	cmd := concat(" ", input[i].Value)
	contains(cmd, "apt-get install")
	not contains(cmd, "--no-install-recommends")
	msg := "apt-get install without --no-install-recommends bloats the image"
}

deny contains msg if {
	some i
	input[i].Cmd == "run"
	cmd := concat(" ", input[i].Value)
	contains(cmd, "apt-get update")
	not contains(cmd, "rm -rf /var/lib/apt/lists")
	msg := "apt-get update without clearing /var/lib/apt/lists leaves the cache in the layer"
}

# Secrets baked into ENV survive in the image history forever, even if later unset.
deny contains msg if {
	some i
	input[i].Cmd == "env"
	kv := lower(concat(" ", input[i].Value))
	some pattern in ["password", "api_key", "apikey", "secret_key", "token", "private_key"]
	contains(kv, pattern)
	not contains(kv, "placeholder")
	not contains(kv, "not-used")
	msg := sprintf("ENV appears to contain a secret (%s) — inject it at runtime instead", [pattern])
}

warn contains msg if {
	some i
	input[i].Cmd == "add"
	msg := "prefer COPY over ADD unless you need remote-URL or archive extraction semantics"
}
