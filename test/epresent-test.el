;;; epresent-test.el --- Tests for epresent  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run with `make test'.  Everything here must work in batch mode on a
;; machine with no window system, so nothing may create a frame, wait on
;; redisplay, or start a subprocess.

;;; Code:

(require 'ert)
(require 'org)
(require 'epresent)

(defconst epresent-test-fixture-directory
  (expand-file-name "fixtures"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "Directory holding the Org fixtures these tests run against.")

(defconst epresent-test-project-directory
  (file-name-as-directory
   (expand-file-name
    ".." (file-name-directory (or load-file-name buffer-file-name))))
  "Root of the project checkout, one level above test/.")

(defmacro epresent-test-with-fixture (name &rest body)
  "Visit fixture NAME in a temporary Org buffer and evaluate BODY there."
  (declare (indent 1) (debug (form body)))
  `(with-temp-buffer
     (insert-file-contents
      (expand-file-name ,name epresent-test-fixture-directory))
     (let ((org-mode-hook nil))
       (org-mode))
     ,@body))

(ert-deftest epresent-test-harness-works ()
  "The fixture directory exists and `epresent' is loadable."
  (should (file-directory-p epresent-test-fixture-directory))
  (should (featurep 'epresent)))

(ert-deftest epresent-test-loads-without-x11 ()
  "The package loads where the X pointer constants are unbound.

`x-pointer-dot' and its siblings come from term/x-win.el, so they do not
exist on a macOS, Windows, terminal or headless Emacs.  Loading the file
used to signal `void-variable' there, making the package unusable rather
than merely degraded.  Unbinding them first reproduces that Emacs."
  (let* ((default-directory epresent-test-project-directory)
         (emacs (expand-file-name invocation-name invocation-directory))
         (output (get-buffer-create "*epresent-test-x11*"))
         (status (call-process
                  emacs nil output nil
                  "-Q" "--batch"
                  "-l" "test/init.el"
                  "--eval" "(mapc #'makunbound '(x-pointer-dot \
x-pointer-shape x-sensitive-text-pointer-shape x-pointer-invisible))"
                  "-l" "epresent.el")))
    (should (equal 0 status))
    (kill-buffer output)))

(provide 'epresent-test)
;;; epresent-test.el ends here
