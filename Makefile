.PHONY: format check test

format:
	stylua lua tests

check:
	stylua --check lua tests
	$(MAKE) test

test:
	nvim --headless --clean -u tests/smoke.lua +qa
