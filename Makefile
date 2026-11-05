PLUGDIR ?= $(HOME)/.config/micro/plug

.PHONY: link unlink test

link:
	@mkdir -p "$(PLUGDIR)"
	@ln -sfn "$(CURDIR)" "$(PLUGDIR)/shinny"
	@echo "linked $(CURDIR) -> $(PLUGDIR)/shinny"

unlink:
	@rm -f "$(PLUGDIR)/shinny"

test:
	lua5.4 tests/run.lua
	bash tests/integration.sh
