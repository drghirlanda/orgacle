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
          ;; `let*', not `let': WIDTH's and PAGES' initialisers each run a
          ;; `string-match' against INPUT before reading their own capture
          ;; with `match-string', which overwrites whatever match data the
          ;; other initialiser left behind.  `let' evaluates initialisers in
          ;; source order, so today's order (WIDTH before PAGES) only works
          ;; because each one's own `string-match'/`match-string' pair runs
          ;; back-to-back with nothing of the other's in between; swapping
          ;; the two bindings would look like a free reordering but would
          ;; break that pairing.  `let*' pins the ordering explicitly.
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

(provide 'ox-orgacle)
;;; ox-orgacle.el ends here
