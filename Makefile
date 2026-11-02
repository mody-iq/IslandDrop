TARGET := iphone:clang:latest:16.0
ARCHS = arm64e
THEOS_PACKAGE_SCHEME = roothide
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = IslandDrop

IslandDrop_FILES = Tweak.xm
IslandDrop_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
IslandDrop_FRAMEWORKS = UIKit QuartzCore CoreGraphics

include $(THEOS_MAKE_PATH)/tweak.mk
