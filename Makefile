all: AutoRaise AutoRaise.app

clean:
	rm -f AutoRaise

# Workaround for AutoRaise binary being included in the repo itself
.PHONY: AutoRaise
AutoRaise: AutoRaise.out
	cp $^ $@

AutoRaise.out: AutoRaise.mm
	g++ -O2 -Wall -fobjc-arc -o $@ $^ -framework AppKit

AutoRaise.app: AutoRaise.out Info.plist AutoRaise.icns
	cp AutoRaise.out AutoRaise
	./create-app-bundle.sh
