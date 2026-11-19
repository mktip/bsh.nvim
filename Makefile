.PHONY: test deps

# Run the test suite headless (mini.test), one Neovim per test file, in
# parallel (JOBS=n to limit). `make test FILES=tests/test_agent.lua` runs some.
# Also fetches the test-only dependency (mini.nvim) into deps/ on first run.
MINI := deps/mini.nvim

test: $(MINI)
	@tests/run.sh $(FILES)

$(MINI):
	git clone --depth 1 https://github.com/echasnovski/mini.nvim $(MINI)
