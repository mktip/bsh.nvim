.PHONY: test deps

# Run the test suite headless (mini.test). `make test` also fetches the test-only
# dependency (mini.nvim) into deps/ on first run.
MINI := deps/mini.nvim

test: $(MINI)
	nvim --headless --noplugin -u tests/minimal_init.lua \
		-c "lua MiniTest.run()"

$(MINI):
	git clone --depth 1 https://github.com/echasnovski/mini.nvim $(MINI)
