TARGET := iphone:clang:latest:14.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = BaiduPanTroll
BaiduPanTroll_FILES = Tweak.mm
BaiduPanTroll_CFLAGS = -fobjc-arc -Wno-unused-variable -Wno-deprecated-declarations
BaiduPanTroll_EXTRA_LDFLAGS = -Wl,-no_warn_inits
BaiduPanTroll_FRAMEWORKS = UIKit Foundation
BaiduPanTroll_INSTALL_PATH = /usr/lib

include $(THEOS_MAKE_PATH)/library.mk

# 自动在 staging 目录生成 control 文件，解决 make package 报错
before-package::
	@mkdir -p $(THEOS_STAGING_DIR)/DEBIAN
	@echo "Package: com.yourcompany.baidu pantroll" > $(THEOS_STAGING_DIR)/DEBIAN/control
	@echo "Name: BaiduPanTroll" >> $(THEOS_STAGING_DIR)/DEBIAN/control
	@echo "Version: 1.0.0" >> $(THEOS_STAGING_DIR)/DEBIAN/control
	@echo "Architecture: iphoneos-arm64" >> $(THEOS_STAGING_DIR)/DEBIAN/control
	@echo "Description: BaiduPan TrollStore Plugin" >> $(THEOS_STAGING_DIR)/DEBIAN/control
	@echo "Maintainer: Your Name" >> $(THEOS_STAGING_DIR)/DEBIAN/control
	@echo "Author: Your Name" >> $(THEOS_STAGING_DIR)/DEBIAN/control
	@echo "Section: Tweaks" >> $(THEOS_STAGING_DIR)/DEBIAN/control
