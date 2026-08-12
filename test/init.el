;;; init.el --- Batch bootstrap for the orgacle test suite  -*- lexical-binding: t; -*-

;;; Commentary:

;; Loaded with -l before every batch target in the Makefile.  Provisions the
;; packages needed to lint and test orgacle into ./.deps, so that `make'
;; needs nothing on the machine but Emacs itself, and puts the project root
;; on `load-path'.

;;; Code:

(require 'package)
(require 'seq)

;; `make compile' leaves orgacle.elc on disk, and `load' prefers a .elc
;; over a newer .el unless told otherwise -- which would silently test
;; the previous version of the code after every edit.
(setq load-prefer-newer t)

(defconst orgacle-dev-dependencies '(package-lint)
  "Packages needed to lint and test orgacle, but not to use it.")

(setq package-user-dir (expand-file-name ".deps" default-directory)
      package-archives '(("gnu"   . "https://elpa.gnu.org/packages/")
                         ("melpa" . "https://melpa.org/packages/")))

(package-initialize)

(let ((missing (seq-remove #'package-installed-p orgacle-dev-dependencies)))
  (when missing
    (package-refresh-contents)
    (mapc #'package-install missing)))

(add-to-list 'load-path default-directory)

(provide 'init)
;;; init.el ends here
