# FrEQ — system-wide parametric EQ for macOS
#
# Targets:
#   make            build driver + app (universal, ad-hoc signed)
#   make driver     build the HAL plug-in only
#   make app        build the menu-bar app only
#   make test       run ring-buffer + parser test suites
#   make install    install driver (sudo) and copy app to /Applications
#   make uninstall  remove driver + app (sudo)
#   make dmg        build a shareable build/FrEQ.dmg (app + driver + installer)
#   make clean      remove build products
#
# Distribution signing: make SIGN="Developer ID Application: Your Name (TEAMID)"

SIGN ?=

SIGNFLAG :=
ifneq ($(SIGN),)
SIGNFLAG := --sign "$(SIGN)"
endif

.PHONY: all driver app test install uninstall dmg clean

all: driver app

driver:
	scripts/build-driver.sh $(SIGNFLAG)

app:
	scripts/build-app.sh $(SIGNFLAG)

test:
	scripts/run-tests.sh

install: all
	scripts/install-driver.sh
	# sudo: a previous sudo-installed copy is root-owned and TCC blocks
	# unprivileged replacement of app bundles in /Applications.
	sudo rm -rf /Applications/FrEQ.app
	sudo cp -R build/FrEQ.app /Applications/FrEQ.app
	sudo chown -R "$$(id -un):$$(id -gn)" /Applications/FrEQ.app
	@echo "Installed. Launch FrEQ from /Applications."

uninstall:
	scripts/uninstall.sh

dmg:
	scripts/create-dmg.sh $(SIGNFLAG)

clean:
	rm -rf build
