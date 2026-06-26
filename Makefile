TARGET := iphone:clang:latest:13.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = BaiduPanTroll

BaiduPanTroll_FILES = Tweak.mm
BaiduPanTroll_CFLAGS = -fobjc-arc -Wno-unused-variable
BaiduPanTroll_FRAMEWORKS = UIKit Foundation
BaiduPanTroll_INSTALL_PATH = /usr/lib

include $(THEOS_MAKE_PATH)/library.mk
