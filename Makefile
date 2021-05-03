.PHONY: all clean install

all: AutoRaise AutoRaise.app

clean:
	rm -f AutoRaise
	rm -rf AutoRaise.app

install: AutoRaise.app
	rm -rf /Applications/AutoRaise.app
	cp -r AutoRaise.app /Applications/

AutoRaise: AutoRaise.mm
	g++ -O2 -Wall -fobjc-arc -o $@ $^ -framework AppKit

AutoRaise.app: AutoRaise Info.plist AutoRaise.icns
	./create-app-bundle.sh
