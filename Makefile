EMACS ?= emacs
BATCH  = $(EMACS) -Q --batch -l test/init.el
EL     = orgacle-core.el orgacle.el

.PHONY: all deps compile checkdoc lint test clean

all: compile checkdoc lint test

deps:
	$(BATCH) --eval '(message "dependencies ready in %s" package-user-dir)'

compile:
	@rm -f $(EL:.el=.elc)
	$(BATCH) --eval '(setq byte-compile-error-on-warn t)' \
	         -f batch-byte-compile $(EL)

checkdoc:
	$(BATCH) -l test/checkdoc-batch.el $(EL)

lint:
	$(BATCH) --eval '(require (quote package-lint))' \
	         --eval '(setq package-lint-main-file "orgacle.el")' \
	         -f package-lint-batch-and-exit $(EL)

test:
	$(BATCH) -l test/orgacle-test.el -f ert-run-tests-batch-and-exit

clean:
	rm -f *.elc
	rm -rf .deps
