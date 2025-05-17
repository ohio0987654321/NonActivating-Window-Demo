# Makefile for Final Discord Window Modifier
all: build/libdiscord_final.dylib

build:
	mkdir -p build

build/libdiscord_final.dylib: discord_final.m
	clang -g -Wall -dynamiclib -fobjc-arc -framework AppKit -framework Foundation -o build/libdiscord_final.dylib discord_final.m

clean:
	rm -rf build

.PHONY: all clean