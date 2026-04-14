VERSION := 1.1.0
KPZ     := SciBack-InstantNotify-$(VERSION).kpz

.PHONY: all build clean

all: build

build:
	@echo "Building $(KPZ)..."
	@zip -r $(KPZ) Koha/
	@echo "Done: $(KPZ)"
	@echo "Install via: Koha Staff → Administration → Plugins → Upload plugin"

clean:
	@rm -f SciBack-InstantNotify-*.kpz

version:
	@echo $(VERSION)
