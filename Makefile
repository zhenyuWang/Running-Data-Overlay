APP_PATH := build/Run Overlay.app

.PHONY: build run test test-unit test-fit clean

build:
	./scripts/build.sh

run: build
	pkill -x "Run Overlay" 2>/dev/null || true
	open "$(APP_PATH)"

test: test-unit

test-unit:
	swift test

test-fit:
	mkdir -p build
	swiftc Sources/RunningDataOverlay/FitParser.swift Tests/FitParserSmokeTest.swift -o build/FitParserSmokeTest
	build/FitParserSmokeTest test.fit

clean:
	rm -rf build
