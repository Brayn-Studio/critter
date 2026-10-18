.PHONY: build test app install uninstall android android-install android-setup

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

ANDROID_SDK ?= $(HOME)/Library/Android/sdk
ANDROID_KEYSTORE ?= $(HOME)/.android/critter-release.jks
ADB ?= $(ANDROID_SDK)/platform-tools/adb

# Writes android/local.properties and, on first run, a release keystore outside the repo.
android-setup:
	@echo "sdk.dir=$(ANDROID_SDK)" > android/local.properties
	@if [ ! -f android/keystore.properties ]; then \
		mkdir -p "$$(dirname "$(ANDROID_KEYSTORE)")"; \
		pass=$$(openssl rand -hex 16); \
		rm -f "$(ANDROID_KEYSTORE)"; \
		keytool -genkeypair -keystore "$(ANDROID_KEYSTORE)" -alias critter -keyalg RSA -keysize 2048 \
			-validity 36500 -storepass "$$pass" -keypass "$$pass" -dname "CN=Critter" >/dev/null && \
		printf 'storeFile=%s\nstorePassword=%s\nkeyAlias=critter\nkeyPassword=%s\n' \
			"$(ANDROID_KEYSTORE)" "$$pass" "$$pass" > android/keystore.properties; \
	fi

android: android-setup
	cd android && ./gradlew :core:test :app:assembleRelease

android-install:
	$(ADB) install -r android/app/build/outputs/apk/release/app-release.apk
	$(ADB) shell am start -n local.critter.phone/.ui.MainActivity
