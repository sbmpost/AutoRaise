#!/bin/bash

g++ -O2 -Wall -fobjc-arc -o AutoRaise AutoRaise.mm -framework AppKit && \
rm -rf AutoRaise.app &&
mkdir -p AutoRaise.app/Contents/MacOS && \
mkdir AutoRaise.app/Contents/Resources && \
cp AutoRaise AutoRaise.app/Contents/MacOS && \
cp Info.plist AutoRaise.app/Contents &&
cp AutoRaise.icns AutoRaise.app/Contents/Resources &&
chmod 700 AutoRaise.app
