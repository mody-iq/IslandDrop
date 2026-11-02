TARGET := iphone:clang:latest:16.0
ARCHS = arm64e
THEOS_PACKAGE_SCHEME = roothide

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = IslandDropPrefs

IslandDropPrefs_FILES = IDPRootListController.m
IslandDropPrefs_FRAMEWORKS = UIKit
IslandDropPrefs_INSTALL_PATH = /Library/PreferenceBundles
IslandDropPrefs_CFLAGS = -fobjc-arc
IslandDropPrefs_LDFLAGS = -undefined dynamic_lookup

include $(THEOS_MAKE_PATH)/bundle.mk
