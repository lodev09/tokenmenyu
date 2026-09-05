APP_NAME = TokenMenyu
DIST = dist/$(APP_NAME).app
PRODUCT = .build/Build/Products/Release/$(APP_NAME).app

build:
	xcodegen
	xcodebuild -project TokenMenyu.xcodeproj -scheme TokenMenyu -configuration Release -derivedDataPath .build build
	rm -rf "$(DIST)"
	mkdir -p dist
	cp -R "$(PRODUCT)" "$(DIST)"

run: build
	open "$(DIST)"

install: build
	rm -rf "/Applications/$(APP_NAME).app"
	cp -R "$(DIST)" /Applications/

clean:
	rm -rf .build dist TokenMenyu.xcodeproj
