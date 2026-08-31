JENOVA_ROOT ?= ..
.PHONY: all check clean
all: check
# test-health.sh was removed from this list and archived on 2026-08-31 (D-AH).
# It was the last shell health test for the archived Lua proxy: it shelled to
# python3, which `make deps` does not install, and it started no server of its
# own, so it aborted this target on its first line unless something happened to
# be listening. jenova-core covers health in-binary — `backends health` probes
# the port, and the self-test subcommands cover the rest. B-24 dies with it.
check:
	@sh test_api_db.sh
	@sh test_api_fs.sh
	@sh test_routes.sh
	@sh test_lifecycle.sh
	@sh test_models.sh
clean:
	@echo "Nothing to clean."
