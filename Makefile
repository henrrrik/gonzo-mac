.PHONY: build install debug test clean
build:
	bash scripts/build-app.sh release
install: build
	bash scripts/install-app.sh
debug:
	bash scripts/build-app.sh debug
test:
	swift test
clean:
	swift package clean
