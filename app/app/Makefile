ifeq ($(THEOS),)
THEOS := $(HOME)/theos
endif

export THEOS_PACKAGE_SCHEME = rootless

# iOS 15-16 là arm64-only; không build armv7 (kéo min-iOS xuống gây lỗi API unavailable).
ARCHS = arm64
TARGET = iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = iOSAutoApp

iOSAutoApp_FILES = $(wildcard src/*.m)
iOSAutoApp_FRAMEWORKS = UIKit Foundation WebKit AVFoundation
iOSAutoApp_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/application.mk

# BẪY 4: application.mk KHÔNG tự copy Info.plist/icon vào .app → tự copy trong before-package.
before-package::
	@echo ">> copy Info.plist + icon + device_profiles.json vào .app"
	cp -f "$(THEOS_PROJECT_DIR)/Resources/Info.plist" \
	      "$(THEOS_STAGING_DIR)/Applications/iOSAutoApp.app/Info.plist"
	cp -f "$(THEOS_PROJECT_DIR)/Resources/"*.png \
	      "$(THEOS_STAGING_DIR)/Applications/iOSAutoApp.app/"
	cp -f "$(THEOS_PROJECT_DIR)/Resources/device_profiles.json" \
	      "$(THEOS_STAGING_DIR)/Applications/iOSAutoApp.app/device_profiles.json"
