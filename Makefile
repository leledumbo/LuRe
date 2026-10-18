# Build wrapper for lurepas (Lua 5.5.1 in Free Pascal).
#
#   make                 list the possible targets
#   make x86_64-linux    build bin/x86_64-linux/lua, units in units/x86_64-linux
#
# Every target has its own output directories, so several platforms can be
# built side by side without interfering with each other.

FPC      ?= fpc
# compiler optimization flags; override for a tuned build, e.g.
#   make x86_64-linux FPCFLAGS='-O4 -CpZEN3 -OpZEN3 -CX -XX -Xs'
# (the binary is rebuilt when the flags change)
FPCFLAGS ?= -O2

# <cpu>-<os> names understood by 'fpc -P<cpu> -T<os>'
TARGETS := x86_64-linux i386-linux aarch64-linux arm-linux \
           x86_64-darwin aarch64-darwin \
           x86_64-freebsd x86_64-win64 i386-win32

# the platform of the installed compiler
NATIVE := $(shell $(FPC) -iTP 2>/dev/null)-$(shell $(FPC) -iTO 2>/dev/null)

SRC := $(wildcard src/*.pas)

.DEFAULT_GOAL := help

.PHONY: help bench clean clean-all FORCE $(TARGETS)

FORCE:

help:
	@echo "Usage: make <FPCTARGET>"
	@echo
	@echo "Possible values of FPCTARGET:"
	@for t in $(TARGETS); do \
	  if [ "$$t" = "$(NATIVE)" ]; then echo "  $$t   (native)"; else echo "  $$t"; fi; \
	done
	@echo
	@echo "  bench             time tools/bench/*.lua (native LuRe, and the reference if built)"
	@echo "  clean-all         remove bin/ and units/"
	@echo "  clean-<FPCTARGET> remove the output of one target"
	@echo
	@echo "Executables go to bin/<FPCTARGET>, compiled units to units/<FPCTARGET>."
	@echo "Cross targets need the matching FPC cross compiler and RTL installed."

# $(1) = target name; the cpu is the part before the first '-', the os the rest
define target_rule
$(1): bin/$(1)/lua

# records the flags so that a change of FPCFLAGS triggers a rebuild
units/$(1)/.flags: FORCE
	@mkdir -p units/$(1)
	@echo '$$(FPCFLAGS)' | cmp -s - $$@ || echo '$$(FPCFLAGS)' > $$@

bin/$(1)/lua: $(SRC) units/$(1)/.flags
	@mkdir -p bin/$(1) units/$(1)
	@rm -f units/$(1)/*.ppu units/$(1)/*.o
	$(FPC) $(FPCFLAGS) -P$$(firstword $$(subst -, ,$(1))) -T$$(patsubst $$(firstword $$(subst -, ,$(1)))-%,%,$(1)) \
	  -FUunits/$(1) -FEbin/$(1) -Fusrc -olua src/lua.pas

clean-$(1):
	rm -rf bin/$(1) units/$(1)
endef

$(foreach t,$(TARGETS),$(eval $(call target_rule,$(t))))

# time the micro benchmarks of tools/bench with LuRe (native) and, when built, the reference Lua
REFLUA := lua-5.5.1/src/lua
bench: $(NATIVE)
	@tools/bench/run.sh $(wildcard $(REFLUA)) bin/$(NATIVE)/lua

clean-all:
	rm -rf bin units

clean: clean-all
