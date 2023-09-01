SKYLIGHT_AVAILABLE := $(shell test -d /System/Library/PrivateFrameworks/SkyLight.framework && echo 1 || echo 0)
override CXXFLAGS += -O2 -Wall -fobjc-arc -D"NS_FORMAT_ARGUMENT(A)=" -D"SKYLIGHT_AVAILABLE=$(SKYLIGHT_AVAILABLE)"

.PHONY: all clean install

all: AutoRaise AutoRaise.app

clean:
	rm -f AutoRaise
	rm -rf AutoRaise.app

install: AutoRaise.app
	rm -rf /Applications/AutoRaise.app
	cp -r AutoRaise.app /Applications/

AutoRaise: AutoRaise.mm
        ifeq ($(SKYLIGHT_AVAILABLE), 1)
	    g++ $(CXXFLAGS) -o $@ $^ -framework AppKit -F /System/Library/PrivateFrameworks -framework SkyLight
        else
	    g++ $(CXXFLAGS) -o $@ $^ -framework AppKit
        endif

AutoRaise.app: AutoRaise Info.plist AutoRaise.icns
	./create-app-bundle.sh
