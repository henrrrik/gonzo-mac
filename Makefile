.PHONY: build debug test clean
build:
	bash scripts/build-app.sh release
debug:
	bash scripts/build-app.sh debug
test:
	swift test
clean:
	swift package clean
