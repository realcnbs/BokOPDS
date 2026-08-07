NICKELHOOK ?= ../vendor/NickelHook/
include $(NICKELHOOK)NickelHook.mk

override LIBRARY  := libbokopds.so
override SOURCES  += src/bokopds_hook.cc
override PKGCONF  += Qt5Widgets
override CFLAGS   += -Wall -Wextra -Werror -fvisibility=hidden
override CXXFLAGS += -Wall -Wextra -Werror -Wno-missing-field-initializers \
                     -isystemlib -fvisibility=hidden -fvisibility-inlines-hidden

override KOBOROOT += ../device-runtime/launch.sh:/mnt/onboard/.adds/bokopds/launch.sh
override KOBOROOT += ../assets/menu-book.png:/mnt/onboard/.adds/bokopds/menu-book.png
override KOBOROOT += ../assets/menu-book-active.png:/mnt/onboard/.adds/bokopds/menu-book-active.png

include $(NICKELHOOK)NickelHook.mk
