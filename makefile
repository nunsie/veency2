TARGET := iphone:7.0:2.0
ARCHS := armv6 #arm64
PACKAGE_VERSION := $(shell ./version.sh)

include theos/makefiles/common.mk

TWEAK_NAME := Veency
Veency_FILES := Tweak.mm SpringBoardAccess.c

Veency_FRAMEWORKS := 
Veency_FRAMEWORKS += CoreSurface
Veency_FRAMEWORKS += GraphicsServices
Veency_FRAMEWORKS += IOMobileFramebuffer
Veency_FRAMEWORKS += QuartzCore
Veency_FRAMEWORKS += UIKit

ADDITIONAL_OBJCFLAGS += -Wno-gnu
ADDITIONAL_OBJCFLAGS += -Wno-dangling-else

ADDITIONAL_OBJCFLAGS += -Isysroot/usr/include
ADDITIONAL_OBJCFLAGS += -idirafter .

ADDITIONAL_CFLAGS += -fvisibility=hidden

ADDITIONAL_LDFLAGS += -Lsysroot/usr/lib -lvncserver
ADDITIONAL_LDFLAGS += -F/System/Library/PrivateFrameworks
ADDITIONAL_LDFLAGS += -weak_reference_mismatches weak

include $(THEOS_MAKE_PATH)/tweak.mk
