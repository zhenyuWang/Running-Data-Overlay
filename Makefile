APP_PATH := build/RunningDataOverlay.app

.PHONY: build run test-fit clean

build:
	./scripts/build.sh

run: build
	pkill -x RunningDataOverlay 2>/dev/null || true
	open -n $(APP_PATH)

test-fit:
	mkdir -p build
	swiftc Sources/RunningDataOverlay/FitParser.swift Tests/FitParserSmokeTest.swift -o build/FitParserSmokeTest
	build/FitParserSmokeTest test.fit

clean:
	rm -rf build