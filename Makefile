# Makefile
TARGET := iphone:clang:latest:15.0
ARCHS = arm64e

LIBRARY_NAME = BaiduPanTroll

BaiduPanTroll_FILES = Tweak.mm
BaiduPanTroll_FRAMEWORKS = UIKit Foundation
BaiduPanTroll_CFLAGS = -fobjc-arc -Wno-unused-function -Wno-unused-variable -Wno-unneeded-internal-declaration -Wno-deprecated-declarations
BaiduPanTroll_LDFLAGS = -Wl,-segalign,4000

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/library.mk
