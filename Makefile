.PHONY: build test app install uninstall

build:
	swift build

test:
	swift test

app:
	./scripts/build-app.sh

install:
	./scripts/install.sh

uninstall:
	./scripts/uninstall.sh
