ifeq ($(THEOS),)
THEOS := $(HOME)/theos
endif

export THEOS_PACKAGE_SCHEME = rootless

# PHẢI có arm64e: trên A12+ (SE2/A13, iPhone 11…) SpringBoard & mọi tiến trình hệ
# thống chạy arm64e và CHỈ nạp được dylib có slice arm64e. Chỉ build arm64 → dyld
# SpringBoard từ chối ("incompatible architecture, need arm64e") → SHOT/OCR/DUMP chết
# (chúng cần CARenderServer chạy TRONG SpringBoard). App thường (arm64) vẫn nạp bình thường.
ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = iOSAutoTouch

iOSAutoTouch_FILES = src/Tweak.mm
iOSAutoTouch_FRAMEWORKS = UIKit Foundation IOKit IOSurface CoreGraphics QuartzCore
# Vision weak-link: dylib VẪN nạp được vào SpringBoard trên iOS 16 dù Vision chưa resolve.
# (Hard-link Vision khiến dyld của SpringBoard iOS16.2 TỪ CHỐI nạp cả tweak → SHOT/OCR chết.)
# Weak-link Vision + VideoToolbox/CoreMedia/CoreVideo: hard-link framework KHÔNG có sẵn trong
# dyld closure của SpringBoard iOS16 → dyld TỪ CHỐI nạp cả tweak. Weak → nạp lazy khi gọi.
iOSAutoTouch_LDFLAGS = -weak_framework Vision -weak_framework VideoToolbox -weak_framework CoreMedia -weak_framework CoreVideo
iOSAutoTouch_CFLAGS = -fobjc-arc -Wno-deprecated-declarations

include $(THEOS_MAKE_PATH)/tweak.mk
