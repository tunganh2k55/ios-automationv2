ifeq ($(THEOS),)
THEOS := $(HOME)/theos
endif

export THEOS_PACKAGE_SCHEME = rootless

ARCHS = arm64
TARGET = iphone:clang:latest:15.0

# BẪY 1: common.mk phải include TRƯỚC tool.mk (nó định nghĩa THEOS_MAKE_PATH).
include $(THEOS)/makefiles/common.mk

TOOL_NAME = iosautod

iosautod_FILES = $(wildcard src/*.c) $(wildcard src/*.m) $(wildcard lua/*.c)
iosautod_CFLAGS = -fobjc-arc -Isrc -Ilua -Iinclude -DLUA_USE_IOS -Wno-deprecated-declarations -Wno-arc-performSelector-leaks -Wno-error
# BẪY 2: chỉ link framework có gọi symbol thật (Foundation/CoreFoundation).
# SpringBoardServices / LaunchServices nạp qua dlopen → KHÔNG link.
# IOSurface/CoreGraphics/ImageIO: chụp framebuffer (fbcap.m). IOMobileFramebuffer +
# IOSurfaceAccelerator nạp qua dlopen/dlsym → KHÔNG link.
# SystemConfiguration (proxy) + LaunchServices (openUrl): API bị "prohibited" trên iOS SDK →
# nạp động dlopen/dlsym trong luaext.m, KHÔNG link.
iosautod_FRAMEWORKS = Foundation CoreFoundation IOSurface CoreGraphics ImageIO Security Vision

# ===== VNC SERVER (libvncserver) =====
# Enable VNC server tích hợp (comment dòng dưới để tắt)
iosautod_CFLAGS += -DHAVE_LIBVNCSERVER
iosautod_LDFLAGS = -Llib
iosautod_LIBRARIES = vncserver turbojpeg png18 lzo2 ssl crypto sasl2 z

iosautod_INSTALL_PATH = /usr/local/iosauto/bin

include $(THEOS_MAKE_PATH)/tool.mk

# BẪY 3+4: before-package chạy SAU khi layout đã stage.
#  - copy web/ vào staging (jbroot của .deb),
#  - nhúng entitlement bằng ldid -S (TOOL không tự nhúng qua CODESIGN_FLAGS),
#  - thêm maintainer scripts vào DEBIAN.
WEB_SRC = $(THEOS_PROJECT_DIR)/../web

before-package::
	@echo ">> stage web/"
	mkdir -p "$(THEOS_STAGING_DIR)/usr/local/iosauto/web"
	cp -f "$(WEB_SRC)"/*.html "$(WEB_SRC)"/*.js "$(WEB_SRC)"/*.css "$(THEOS_STAGING_DIR)/usr/local/iosauto/web/"
	cp -f "$(WEB_SRC)"/*.png "$(THEOS_STAGING_DIR)/usr/local/iosauto/web/" 2>/dev/null || true
	@echo ">> stage novnc/"
	if [ -d "$(WEB_SRC)/novnc" ]; then cp -r "$(WEB_SRC)/novnc" "$(THEOS_STAGING_DIR)/usr/local/iosauto/web/"; fi
	@echo ">> nhúng entitlements"
	ldid -S"$(THEOS_PROJECT_DIR)/entitlements.plist" "$(THEOS_STAGING_DIR)/usr/local/iosauto/bin/iosautod"
	@echo ">> maintainer scripts"
	mkdir -p "$(THEOS_STAGING_DIR)/DEBIAN"
	cp -f "$(THEOS_PROJECT_DIR)/postinst" "$(THEOS_STAGING_DIR)/DEBIAN/postinst"
	cp -f "$(THEOS_PROJECT_DIR)/prerm" "$(THEOS_STAGING_DIR)/DEBIAN/prerm"
	chmod 0755 "$(THEOS_STAGING_DIR)/DEBIAN/postinst" "$(THEOS_STAGING_DIR)/DEBIAN/prerm"
