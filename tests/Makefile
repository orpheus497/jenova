JENOVA_ROOT ?= ..
.PHONY: all check clean
all: check
check:
	@sh test-health.sh
	@sh test_api_db.sh
	@sh test_api_fs.sh
	@sh test_routes.sh
	@sh test_lifecycle.sh
clean:
	@echo "Nothing to clean."
