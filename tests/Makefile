JENOVA_ROOT ?= ..

.PHONY: all check clean

all: check

check:
	@sh test-health.sh
	@sh test-launcher.sh
	@sh proxy-concurrency/all.sh
	@sh test_api_db.sh
	@sh test_api_fs.sh
	@sh test_routes.sh

clean:
	@echo "Nothing to clean."
