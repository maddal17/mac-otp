.PHONY: build test install run clean

build:
	@bash Scripts/build.sh

test: build

install: build
	@mkdir -p "$(HOME)/Applications"
	@rm -rf "$(HOME)/Applications/MacOTP.app"
	@cp -R dist/MacOTP.app "$(HOME)/Applications/MacOTP.app"
	@echo "Installed to $(HOME)/Applications/MacOTP.app"

run: build
	@open dist/MacOTP.app

clean:
	@rm -rf .build dist
