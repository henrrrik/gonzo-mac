.PHONY: build install dmg debug test clean
build:
	bash scripts/build-app.sh release
install: build
	bash scripts/install-app.sh
dmg: build
	bash scripts/make-dmg.sh
debug:
	bash scripts/build-app.sh debug
test:
	swift test
clean:
	swift package clean
