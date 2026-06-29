TARGET := iphone:clang:latest:14.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = BaiduPanTroll

BaiduPanTroll_FILES = Tweak.xm
BaiduPanTroll_CFLAGS = -fobjc-arc -Wno-unused-variable -Wno-deprecated-declarations
BaiduPanTroll_FRAMEWORKS = UIKit Foundation
BaiduPanTroll_INSTALL_PATH = /usr/lib

include $(THEOS_MAKE_PATH)/library.mk
