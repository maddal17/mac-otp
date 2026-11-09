.PHONY: build test install run clean

build:
	@bash Scripts/build.sh

test: build

install: build
	@if [ -w "/Applications" ]; then \
		rm -rf "/Applications/MacOTP.app"; \
		cp -R dist/MacOTP.app "/Applications/MacOTP.app"; \
		echo "Installed to /Applications/MacOTP.app"; \
	else \
		mkdir -p "$(HOME)/Applications"; \
		rm -rf "$(HOME)/Applications/MacOTP.app"; \
		cp -R dist/MacOTP.app "$(HOME)/Applications/MacOTP.app"; \
		echo "Installed to $(HOME)/Applications/MacOTP.app"; \
	fi

run: build
	@open dist/MacOTP.app

clean:
	@rm -rf .build dist
