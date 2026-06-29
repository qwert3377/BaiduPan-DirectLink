TARGET := iphone:clang:latest:14.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = BaiduPanTroll

BaiduPanTroll_FILES = Tweak.mm
BaiduPanTroll_CFLAGS = -fobjc-arc -Wno-error
BaiduPanTroll_LDFLAGS = -Wl,-segalign,4000

include $(THEOS_MAKE_PATH)/tweak.mk
