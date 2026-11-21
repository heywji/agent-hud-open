APP := build/Agent HUD Open.app

.PHONY: build test check run clean

build:
	@scripts/build-app.sh debug

check:
	python3 scripts/check-source-boundaries.py

test:
	swift test

run: build
	open "$(APP)"

clean:
	rm -rf .build build
