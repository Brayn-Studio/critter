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
ANDROID_KEYSTORE_BACKUP ?= $(HOME)/.android/critter-release.backup
ADB ?= $(ANDROID_SDK)/platform-tools/adb

# Writes android/local.properties and, the first time only, a release keystore outside the
# repo plus android/keystore.properties (and copies of both in ANDROID_KEYSTORE_BACKUP). An
# existing keystore is never deleted or replaced: the installed app only takes updates signed
# with the same key. The password reaches keytool through a 0600 file, not its argv.
android-setup:
	@echo "sdk.dir=$(ANDROID_SDK)" > android/local.properties
	@set -e; \
	if [ -f android/keystore.properties ]; then exit 0; fi; \
	if [ -e "$(ANDROID_KEYSTORE)" ]; then \
		echo "error: $(ANDROID_KEYSTORE) exists, but android/keystore.properties is missing." >&2; \
		echo "       Restore android/keystore.properties from $(ANDROID_KEYSTORE_BACKUP)/ (or rewrite it with" >&2; \
		echo "       that keystore's password). Don't delete the keystore: the app on the phone can only" >&2; \
		echo "       be updated with the same key." >&2; \
		exit 1; \
	fi; \
	umask 077; \
	mkdir -p "$$(dirname "$(ANDROID_KEYSTORE)")" "$(ANDROID_KEYSTORE_BACKUP)"; \
	passfile=$$(mktemp); trap 'rm -f "$$passfile"' EXIT; \
	openssl rand -hex 16 > "$$passfile"; \
	keytool -genkeypair -keystore "$(ANDROID_KEYSTORE)" -alias critter -keyalg RSA -keysize 2048 \
		-validity 36500 -storepass:file "$$passfile" -keypass:file "$$passfile" -dname "CN=Critter" >/dev/null; \
	pass=$$(cat "$$passfile"); \
	printf 'storeFile=%s\nstorePassword=%s\nkeyAlias=critter\nkeyPassword=%s\n' \
		"$(ANDROID_KEYSTORE)" "$$pass" "$$pass" > android/keystore.properties; \
	cp "$(ANDROID_KEYSTORE)" android/keystore.properties "$(ANDROID_KEYSTORE_BACKUP)/"; \
	echo "Made $(ANDROID_KEYSTORE); copies of it and of android/keystore.properties are in $(ANDROID_KEYSTORE_BACKUP)/."

android: android-setup
	cd android && ./gradlew :core:test :app:assembleRelease

android-install:
	$(ADB) install -r android/app/build/outputs/apk/release/app-release.apk
	$(ADB) shell am start -n local.critter.phone/.ui.MainActivity
