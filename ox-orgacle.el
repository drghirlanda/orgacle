;;; ox-orgacle.el --- LaTeX and PDF export for Orgacle  -*- lexical-binding: t; -*-

;; This file is part of Orgacle.  See orgacle.el for the package header,
;; copyright and licence.

;;; Commentary:

;; LaTeX and PDF export for Orgacle: an `orgacle' export backend,
;; derived from `latex', that translates ORGACLE_ property drawers --
;; showing files and videos -- into their LaTeX equivalent, plus the
;; commands to export a buffer through it as a LaTeX buffer, a LaTeX
;; file, or a compiled PDF.  This file deliberately does not require
;; orgacle-core, so an Org file can be exported through this backend
;; without starting a presentation.

;;; Code:

(require 'ox)
(require 'ox-latex)
(require 'ox-org)

(defun orgacle-latex-property-drawer (blob contents _info)
  "Translate the property drawer BLOB with CONTENTS into LaTeX.
ORGACLE_VIDEO_ALT becomes a bracketed note naming the file.
ORGACLE_SHOW_FILE becomes an included Org file when it names one, and
an \\includegraphics otherwise, honouring ORGACLE_SHOW_WIDTH and
ORGACLE_SHOW_PAGES."
  (let ((input (org-export-expand blob contents t))
        (output nil))
    ;; videos are named, not embedded
    (when (string-match "ORGACLE_VIDEO_ALT:\s+\\(.+\\)" input)
      (setq output (concat output "\n[ Video: " (match-string 1 input) " ]\n\n")))
    (when (string-match "ORGACLE_SHOW_FILE:\s+\\(.+\\)" input)
      (let* ((filename (replace-regexp-in-string
                        "\\]?\\]?$" ""
                        (replace-regexp-in-string
                         "^\\[?\\[?" "" (match-string 1 input))))
             (extension (file-name-extension filename)))
        (if (string= extension "org")
            ;; Org files are converted to LaTeX and inlined.  Read the file
            ;; into a temporary buffer rather than visiting it: visiting
            ;; would hand us the user's own buffer if they have the file
            ;; open, and the conversion replaces the buffer's contents.
            (setq output
                  (concat output
                          (with-temp-buffer
                            (insert-file-contents filename)
                            (org-export-string-as (buffer-string) 'latex t))))
          ;; everything else is treated as an image
          ;; `let*' states sequential intent, not a fix: WIDTH and PAGES are
          ;; independent, each running its own `string-match' immediately
          ;; before its own `match-string', so the order does not matter.
          (let* ((width (if (string-match "ORGACLE_SHOW_WIDTH:\s+\\(.+\\)" input)
                            (match-string 1 input)
                          "0.5"))
                 (pages (if (string-match "ORGACLE_SHOW_PAGES:\s+\\(.+\\)" input)
                            (split-string (match-string 1 input))
                          '("1"))))
            (setq output (concat output "\n"))
            (dolist (page pages)
              (setq output
                    (concat output
                            "\\includegraphics[width=" width
                            "\\textwidth,page=" page "]{" filename "}\n")))))))
    output))

(org-export-define-derived-backend 'orgacle 'latex
  :translate-alist
  '((property-drawer . orgacle-latex-property-drawer))
  :options-alist
  ;; Org drops property drawers unless this is on, which would silently
  ;; disable the translator above.  Default it to t for this backend only.
  '((:with-properties nil "prop" t))
  :menu-entry
  '(?E "Orgacle to LaTeX"
       ((?L "As LaTeX buffer" orgacle-export-as-latex)
	(?l "As LaTeX file" orgacle-export-to-latex)
	(?p "As PDF file" orgacle-export-to-pdf)
	(?o "As PDF file and open"
	    (lambda (a s v b)
	      (if a (orgacle-export-to-pdf t s v b)
		(org-open-file (orgacle-export-to-pdf nil s v b))))))))

;;;###autoload
(defun orgacle-export-as-latex
  (&optional async subtreep visible-only body-only ext-plist)
  "Export the current Orgacle buffer to a LaTeX buffer.
ASYNC, SUBTREEP, VISIBLE-ONLY, BODY-ONLY and EXT-PLIST are passed to
`org-export-to-buffer'; see there for their meaning."
  (interactive)
  (org-export-to-buffer 'orgacle "*Org LATEX Export*"
    async subtreep visible-only body-only ext-plist (lambda () (LaTeX-mode))))

;;;###autoload
(defun orgacle-export-to-latex
  (&optional async subtreep visible-only body-only ext-plist)
  "Export the current buffer to a LaTeX file.
ASYNC, SUBTREEP, VISIBLE-ONLY, BODY-ONLY and EXT-PLIST are passed to
`org-export-to-file'; see there for their meaning."
  (interactive)
  (let ((outfile (org-export-output-file-name ".tex" subtreep)))
    (org-export-to-file 'orgacle outfile
      async subtreep visible-only body-only ext-plist)))

;;;###autoload
(defun orgacle-export-to-pdf
  (&optional async subtreep visible-only body-only ext-plist)
  "Export the current Orgacle buffer to LaTeX, then process it to PDF.
ASYNC, SUBTREEP, VISIBLE-ONLY, BODY-ONLY and EXT-PLIST are passed to
`org-export-to-file'; see there for their meaning."
  (interactive)
  (let ((outfile (org-export-output-file-name ".tex" subtreep)))
    (org-export-to-file 'orgacle outfile
      async subtreep visible-only body-only ext-plist
      (lambda (file) (org-latex-compile file)))))

(defun orgacle--ox-remove-backend ()
  "Remove the `orgacle' export backend from Org's own dispatcher.
`org-export-define-derived-backend', above, registers a backend struct
in `org-export-registered-backends' -- a list Org itself owns, not
something in this file's own `load-history' -- so `unload-feature'
never touches it on its own: unloading this file unbinds
`orgacle-latex-property-drawer', `orgacle-export-as-latex' and the
rest, but leaves the registered backend struct still pointing at all
of them by name.  Confirmed directly, before this fix: after
unloading, `(org-export-get-backend \\='orgacle)' still returned that
struct, `org-export-dispatch' still listed \"[E] Orgacle to LaTeX\"
with all four entries, and choosing any one of them signalled
`void-function'.

Removes only the `orgacle' backend from `org-export-registered-backends',
by name, leaving every other registered backend -- including `latex'
and `org', which `orgacle' derives from and this file also requires --
untouched.

Named `orgacle--ox-remove-backend', not `ox-orgacle-unload-function':
the latter is the name `unload-feature' would auto-discover and call
on its own for the `ox-orgacle' feature -- the usual, idiomatic way to
hook cleanup into unloading a specific file, and the name every other
`FEATURE-unload-function' in this package uses, including
`orgacle-src-unload-function' -- but `ox-orgacle', unlike every other
feature this package provides, does not itself start with `orgacle-',
so a function of that exact name fails `package-lint''s package-prefix
check, which orgacle.el's own `orgacle-unload-function' is not
exempt from either and does not try to be.  Called explicitly instead,
by `orgacle-unload-function', before that function's own cascade
unloads `ox-orgacle' -- which must happen in that order, since this
function itself lives in ox-orgacle.el and would otherwise go void
along with everything else that file defines before ever running."
  (setq org-export-registered-backends
        (delq (org-export-get-backend 'orgacle) org-export-registered-backends)))

(provide 'ox-orgacle)
;;; ox-orgacle.el ends here
