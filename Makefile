.PHONY: build test app install uninstall

build:
	swift build

test:
	swift test

app:
	./scripts/build-app.sh

install:
	@echo "install: implemented in Task 9"

uninstall:
	@echo "uninstall: implemented in Task 9"
