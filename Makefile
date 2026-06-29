TARGET := iphone:clang:latest:14.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = BaiduPanTroll

BaiduPanTroll_FILES = Tweak.xm
BaiduPanTroll_CFLAGS = -fobjc-arc -Wno-unused-variable -Wno-deprecated-declarations
BaiduPanTroll_FRAMEWORKS = UIKit Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
