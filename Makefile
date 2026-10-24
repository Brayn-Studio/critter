.PHONY: build test app install uninstall android android-install android-setup ios-sim ios ios-install ios-test

build:
	swift build

test:
	swift test
	@if command -v node >/dev/null 2>&1; then node --test "integrations/deepseek/test/*.test.js"; fi

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

IOS_SIM ?= platform=iOS Simulator,name=iPhone 17 Pro,OS=latest
ios-sim:
	xcodebuild -project ios/Critter.xcodeproj -scheme Critter -destination '$(IOS_SIM)' -derivedDataPath ios/build build

# Device builds (Release, for the iPhone). Signed by hand: `CODE_SIGN_STYLE[sdk=iphoneos*] = Manual` in
# ios/Config/Base.xcconfig, so Xcode never registers anything with the developer account by itself. `make ios` first
# finds the installed provisioning profile for the app and each extension (scripts/ios-device.sh profiles: this
# team's App ID, not expired, with every entitlement in ios/Config/*.entitlements) and stops, saying what is missing,
# when one is not there; when the profiles are the ones Xcode made, it signs automatically but without
# -allowProvisioningUpdates (only the installed profiles, no account). ALLOW_PROVISIONING=1 instead lets Xcode register
# the App IDs' capabilities and the App Group and make the profiles (-allowProvisioningUpdates, automatic signing for
# this one build): only with the account owner's OK.
IOS_DEVICE_BUILD = xcodebuild -project ios/Critter.xcodeproj -scheme Critter -configuration Release \
	-destination 'generic/platform=iOS' -derivedDataPath ios/build
IOS_DEVICE_APP = ios/build/Build/Products/Release-iphoneos/Critter.app

ios:
	@if [ "$(ALLOW_PROVISIONING)" = "1" ]; then \
		echo "ALLOW_PROVISIONING=1：这会在开发者账号里登记 App ID 能力和 App Group，并生成描述文件。"; \
		$(IOS_DEVICE_BUILD) -allowProvisioningUpdates CODE_SIGN_STYLE=Automatic build; \
	else \
		profiles=$$(scripts/ios-device.sh profiles) || exit 1; \
		$(IOS_DEVICE_BUILD) $$profiles build; \
	fi

# Installs what `make ios` built on the one iPhone connected to this Mac (scripts/ios-device.sh iphone: a real,
# paired, reachable iPhone); stops when there is none or more than one.
ios-install:
	@test -d "$(IOS_DEVICE_APP)" || { echo "make ios-install: $(IOS_DEVICE_APP) is not there: make ios first" >&2; exit 1; }
	@device=$$(scripts/ios-device.sh iphone) || exit 1; \
	xcrun devicectl device install app --device "$$device" "$(IOS_DEVICE_APP)"

# The app and both extensions built for the simulator, then the logic they run, which lives in the package: the iOS
# project has no test target of its own.
ios-test: ios-sim
	swift test --filter 'CritterClientTests|CritterKitTests'
