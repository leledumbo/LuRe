# Build wrapper for lurepas (Lua 5.5.1 in Free Pascal).
#
#   make                 list the possible targets
#   make x86_64-linux    build bin/x86_64-linux/lua, units in units/x86_64-linux
#
# Every target has its own output directories, so several platforms can be
# built side by side without interfering with each other.

FPC      ?= fpc
FPCFLAGS ?= -O2

# <cpu>-<os> names understood by 'fpc -P<cpu> -T<os>'
TARGETS := x86_64-linux i386-linux aarch64-linux arm-linux \
           x86_64-darwin aarch64-darwin \
           x86_64-freebsd x86_64-win64 i386-win32

# the platform of the installed compiler
NATIVE := $(shell $(FPC) -iTP 2>/dev/null)-$(shell $(FPC) -iTO 2>/dev/null)

SRC := $(wildcard src/*.pas)

.DEFAULT_GOAL := help

.PHONY: help clean clean-all $(TARGETS)

help:
	@echo "Usage: make <FPCTARGET>"
	@echo
	@echo "Possible values of FPCTARGET:"
	@for t in $(TARGETS); do \
	  if [ "$$t" = "$(NATIVE)" ]; then echo "  $$t   (native)"; else echo "  $$t"; fi; \
	done
	@echo
	@echo "  clean-all         remove bin/ and units/"
	@echo "  clean-<FPCTARGET> remove the output of one target"
	@echo
	@echo "Executables go to bin/<FPCTARGET>, compiled units to units/<FPCTARGET>."
	@echo "Cross targets need the matching FPC cross compiler and RTL installed."

# $(1) = target name; the cpu is the part before the first '-', the os the rest
define target_rule
$(1): bin/$(1)/lua

bin/$(1)/lua: $(SRC)
	@mkdir -p bin/$(1) units/$(1)
	$(FPC) $(FPCFLAGS) -P$$(firstword $$(subst -, ,$(1))) -T$$(patsubst $$(firstword $$(subst -, ,$(1)))-%,%,$(1)) \
	  -FUunits/$(1) -FEbin/$(1) -Fusrc -olua src/lua.pas

clean-$(1):
	rm -rf bin/$(1) units/$(1)
endef

$(foreach t,$(TARGETS),$(eval $(call target_rule,$(t))))

clean-all:
	rm -rf bin units

clean: clean-all
