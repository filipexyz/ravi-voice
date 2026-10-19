.PHONY: build test app run install uninstall restart logs

build:
	swift build

test:
	swift test

app:
	scripts/build-app.sh

run: app
	build/RaviVoice.app/Contents/MacOS/RaviVoice

install:
	scripts/install.sh

uninstall:
	scripts/install.sh uninstall

restart:
	launchctl kickstart -k gui/$$(id -u)/bot.ravi.voice

logs:
	tail -f ~/Library/Logs/RaviVoice/ravi-voice.log ~/Library/Logs/RaviVoice/transcripts.log
