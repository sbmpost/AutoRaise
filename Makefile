SKYLIGHT_AVAILABLE := $(shell test -d /System/Library/PrivateFrameworks/SkyLight.framework && echo 1 || echo 0)
override CXXFLAGS += -O2 -Wall -fobjc-arc -D"NS_FORMAT_ARGUMENT(A)=" -D"SKYLIGHT_AVAILABLE=$(SKYLIGHT_AVAILABLE)"

.PHONY: all clean install build run debug update test

all: AutoRaise AutoRaise.app

clean:
	rm -f AutoRaise
	rm -rf AutoRaise.app
	rm -f tests/topwindow_test tests/*.o

# Links the real AutoRaise.mm so the predicate under test cannot drift from the one
# that ships. The two objects are compiled separately because -Dmain=autoraise_main
# must apply to AutoRaise.mm only -- applied to the test it would rename its main too.
TEST_FLAGS := -DOLD_ACTIVATION_METHOD -DEXPERIMENTAL_FOCUS_FIRST
TEST_LIBS := -framework AppKit $(if $(filter 1,$(SKYLIGHT_AVAILABLE)),-F /System/Library/PrivateFrameworks -framework SkyLight,)

test: tests/topwindow_test.mm AutoRaise.mm
	g++ $(CXXFLAGS) $(TEST_FLAGS) -Dmain=autoraise_main -c AutoRaise.mm -o tests/autoraise_under_test.o
	g++ $(CXXFLAGS) $(TEST_FLAGS) -c tests/topwindow_test.mm -o tests/topwindow_test.o
	g++ $(CXXFLAGS) -o tests/topwindow_test tests/topwindow_test.o tests/autoraise_under_test.o $(TEST_LIBS)
	./tests/topwindow_test tests/fixture-telegram-photo-viewer.json

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

build: clean
	make CXXFLAGS="-DOLD_ACTIVATION_METHOD -DEXPERIMENTAL_FOCUS_FIRST"

run: build
	./AutoRaise -focusDelay 1

debug: build
	./AutoRaise -focusDelay 1 -verbose 1

update: build install
