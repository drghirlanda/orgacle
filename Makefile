EMACS ?= emacs
BATCH  = $(EMACS) -Q --batch -l test/init.el
EL     = orgacle-core.el orgacle-nav.el orgacle-fontify.el orgacle-src.el orgacle-media.el orgacle-notes.el orgacle-reveal.el orgacle-appearance.el ox-orgacle.el orgacle.el

.PHONY: all deps compile checkdoc lint test clean distclean

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

# `.deps' holds package-lint, fetched from MELPA by test/init.el; keeping
# it out of `clean' is what lets `make clean && make all', the documented
# verification command, run offline after the first `make deps'/`make all'.
distclean: clean
	rm -rf .deps
