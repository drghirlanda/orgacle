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

(ert-deftest epresent-test-harness-prefers-newer-source ()
  "The batch harness loads the newer of epresent.el and epresent.elc.

`load-prefer-newer' defaults to nil, which makes `require' prefer a
stale .elc left behind by `make compile' over freshly edited source --
so a suite run without recompiling would silently test the previous
version of the code."
  (should load-prefer-newer))

;;; Keyword parsing

(ert-deftest epresent-test-frame-level-from-keyword ()
  "`epresent-get-frame-level' reads #+EPRESENT_FRAME_LEVEL."
  (epresent-test-with-fixture "keywords.org"
    (should (equal 2 (epresent-get-frame-level)))))

(ert-deftest epresent-test-frame-level-defaults ()
  "Without the keyword, `epresent-frame-level' is returned unchanged."
  (epresent-test-with-fixture "plain.org"
    (should (equal epresent-frame-level (epresent-get-frame-level)))))

(ert-deftest epresent-test-frame-level-ignores-restriction ()
  "The keyword is found even when the buffer is narrowed past it."
  (epresent-test-with-fixture "keywords.org"
    (goto-char (point-max))
    (org-back-to-heading)
    (org-narrow-to-subtree)
    (should (equal 2 (epresent-get-frame-level)))))

(ert-deftest epresent-test-mode-line-from-keyword ()
  "`epresent-get-mode-line' reads and parses #+EPRESENT_MODE_LINE."
  (epresent-test-with-fixture "keywords.org"
    (should (equal '(:eval (format "slide %d" epresent-page-number))
                   (epresent-get-mode-line)))))

(ert-deftest epresent-test-mode-line-defaults ()
  "Without the keyword, `epresent-mode-line' is returned unchanged."
  (epresent-test-with-fixture "plain.org"
    (should (equal epresent-mode-line (epresent-get-mode-line)))))

;;; Speaker notes

(ert-deftest epresent-test-collect-notes-keeps-slide-headings ()
  "Every frame-level heading contributes a heading to the notes text."
  (epresent-test-with-fixture "notes.org"
    (let ((notes (epresent--collect-notes)))
      (should (string-match-p "^\\* First slide$" notes))
      (should (string-match-p "^\\* Second slide$" notes))
      (should (string-match-p "^\\* Third slide$" notes)))))

(ert-deftest epresent-test-collect-notes-keeps-note-bodies ()
  "The body of each Speaker notes subtree is carried over."
  (epresent-test-with-fixture "notes.org"
    (let ((notes (epresent--collect-notes)))
      (should (string-match-p "One two three four five\\." notes))
      (should (string-match-p "Six seven eight\\." notes)))))

(ert-deftest epresent-test-collect-notes-omits-slide-bodies ()
  "Text outside a Speaker notes subtree is not collected."
  (epresent-test-with-fixture "notes.org"
    (should-not (string-match-p "Visible text" (epresent--collect-notes)))))

(ert-deftest epresent-test-collect-notes-repeats-the-last-heading ()
  "Current behaviour: the final heading is emitted twice.

The loop tests (< (point) (point-max)) before advancing, so on the last
heading its body runs once more with point unmoved.  P3 replaces this
loop with the slide vector; until then the duplication is pinned here so
that the lexical-binding conversion cannot change it unnoticed."
  (epresent-test-with-fixture "notes.org"
    (should (string-match-p "\\* Third slide\n\\* Third slide"
                            (epresent--collect-notes)))))

;;; Speaking time

(ert-deftest epresent-test-speaker-word-count ()
  "Only words inside Speaker notes subtrees are counted.

Twelve: each subtree contributes the two words of its own heading —
`count-words' does not count the leading stars — plus five and three
words of body."
  (epresent-test-with-fixture "notes.org"
    (should (equal 12 (epresent--speaker-word-count)))))

(ert-deftest epresent-test-speaker-word-count-without-notes ()
  "A buffer with no speaker notes counts zero words."
  (epresent-test-with-fixture "plain.org"
    (should (equal 0 (epresent--speaker-word-count)))))

(ert-deftest epresent-test-speaking-time-scales-with-wpm ()
  "Doubling the reading speed halves the estimate."
  (let ((epresent-wpm 150))
    (should (equal 2.0 (epresent--speaking-time 300))))
  (let ((epresent-wpm 300))
    (should (equal 1.0 (epresent--speaking-time 300)))))

;;; Defect fixes

(ert-deftest epresent-test-speaking-time-rounds-to-half-minutes ()
  "225 words at 150 wpm is a minute and a half, not one minute."
  (let ((epresent-wpm 150))
    (should (equal 1.5 (epresent--speaking-time 225)))
    (should (equal 2.0 (epresent--speaking-time 300)))
    (should (equal 0.5 (epresent--speaking-time 1)))))

(ert-deftest epresent-test-slide-in-follows-the-option ()
  "`epresent-slide-in' decides, and the property overrides it."
  (epresent-test-with-fixture "plain.org"
    (let ((epresent-slide-in nil))
      (should-not (epresent--slide-in-p)))
    (let ((epresent-slide-in t))
      (should (epresent--slide-in-p)))))

(ert-deftest epresent-test-slide-in-property-overrides ()
  "EPRESENT_SLIDE_IN turns the animation on or off for one slide."
  (epresent-test-with-fixture "slide-in.org"
    (goto-char (point-min))
    (re-search-forward "^\\* Never$")
    (let ((epresent-slide-in t))
      (should-not (epresent--slide-in-p)))
    (goto-char (point-min))
    (re-search-forward "^\\* Always$")
    (let ((epresent-slide-in nil))
      (should (epresent--slide-in-p)))))

(ert-deftest epresent-test-font-commands-use-real-faces ()
  "Growing and shrinking the font changes every scalable face.
Also, repeated presses of `epresent-decrease-font' -- which mixes
absolute and relative face heights, see `epresent--scale-font' -- must
never signal and must never drive a height to zero or below."
  (let ((original (mapcar (lambda (face)
                            (cons face (face-attribute face :height)))
                          epresent-scalable-faces)))
    (unwind-protect
        (progn
          ;; one press visibly changes every face
          (epresent-increase-font)
          (dolist (face epresent-scalable-faces)
            (should-not (equal (face-attribute face :height)
                               (cdr (assq face original)))))
          (let ((after-grow (mapcar (lambda (face)
                                     (cons face (face-attribute face :height)))
                                   epresent-scalable-faces)))
            ;; the opposite press visibly changes every face again
            (epresent-decrease-font)
            (dolist (face epresent-scalable-faces)
              (should-not (equal (face-attribute face :height)
                                 (cdr (assq face after-grow))))))
          ;; repeated presses never signal and never reach zero or below
          (dotimes (_ 10)
            (should (progn (epresent-decrease-font) t)))
          (dolist (face epresent-scalable-faces)
            (should (> (face-attribute face :height) 0))))
      ;; restore the faces so later tests see the defface heights
      (dolist (pair original)
        (set-face-attribute (car pair) nil :height (cdr pair))))))

(ert-deftest epresent-test-export-includes-properties-by-default ()
  "The backend exports property drawers without being asked.

`org-export-with-properties' defaults to nil, which discarded the very
drawers this backend exists to translate."
  (epresent-test-with-fixture "export.org"
    (should (string-match-p
             "\\\\includegraphics"
             (org-export-as 'epresent nil nil t)))))

;;; LaTeX export backend

(defun epresent-test--export-fixture (name)
  "Export fixture NAME through the epresent backend and return the LaTeX.
`:with-properties' has to be forced on: `org-export-with-properties'
defaults to nil, and without it Org discards property drawers before
the backend ever sees them, so the translator never runs.  Task 9 makes
the backend default it to t; this helper keeps the tests honest either
way."
  (epresent-test-with-fixture name
    (org-export-as 'epresent nil nil t '(:with-properties t))))

(ert-deftest epresent-test-export-emits-includegraphics ()
  "EPRESENT_SHOW_FILE becomes an \\includegraphics with the given width."
  (let ((latex (epresent-test--export-fixture "export.org")))
    (should (string-match-p
             "\\\\includegraphics\\[width=0\\.8\\\\textwidth,page=1\\]{figure\\.pdf}"
             latex))))

(ert-deftest epresent-test-export-strips-org-link-brackets ()
  "A filename written as an Org link loses its brackets."
  (let ((latex (epresent-test--export-fixture "export.org")))
    (should-not (string-match-p "{\\[\\[figure" latex))))

(ert-deftest epresent-test-export-honours-page-list ()
  "EPRESENT_SHOW_PAGES emits one \\includegraphics per page."
  (let ((latex (epresent-test--export-fixture "export.org")))
    (should (string-match-p "page=1\\]{figure\\.pdf}" latex))
    (should (string-match-p "page=3\\]{figure\\.pdf}" latex))))

(ert-deftest epresent-test-export-names-videos ()
  "EPRESENT_VIDEO_ALT becomes a bracketed note naming the file."
  (let ((latex (epresent-test--export-fixture "export.org")))
    (should (string-match-p "\\[ Video: demo\\.mp4 \\]" latex))))

(ert-deftest epresent-test-export-defaults-width ()
  "A drawer with no EPRESENT_SHOW_WIDTH uses half the text width."
  (let ((latex (epresent-test--export-fixture "export.org")))
    (should (string-match-p "width=0\\.5\\\\textwidth" latex))))

(ert-deftest epresent-test-export-inlines-org-files ()
  "An EPRESENT_SHOW_FILE naming an Org file is converted and inlined.

This branch was uncovered when a lexical-binding conversion silently
broke it, so it is pinned here."
  (let ((latex (epresent-test--export-fixture "export-include.org")))
    (should (string-match-p "Included heading" latex))
    (should (string-match-p "\\\\textbf{bold}" latex))))

;;; Fringe indicators

(defun epresent-test--indicators-on-slide (heading)
  "Narrow to HEADING in the indicators fixture and return the fringe bitmaps.
The result is a list of symbols such as `filled-square', in no
particular order."
  (epresent-test-with-fixture "indicators.org"
    (goto-char (point-min))
    (re-search-forward (concat "^\\* " (regexp-quote heading) "$"))
    (org-narrow-to-subtree)
    (let ((epresent-fringe-overlays nil))
      (epresent-show-indicators-maybe)
      (prog1 (mapcar (lambda (ov)
                       (nth 1 (get-text-property
                               0 'display (overlay-get ov 'before-string))))
                     epresent-fringe-overlays)
        (mapc #'delete-overlay epresent-fringe-overlays)))))

(ert-deftest epresent-test-indicator-for-file ()
  "EPRESENT_SHOW_FILE draws a filled square."
  (should (equal '(filled-square)
                 (epresent-test--indicators-on-slide "Slide with a file"))))

(ert-deftest epresent-test-indicator-for-video ()
  "EPRESENT_SHOW_VIDEO draws a hollow square."
  (should (equal '(hollow-square)
                 (epresent-test--indicators-on-slide "Slide with a video"))))

(ert-deftest epresent-test-indicator-for-both ()
  "A slide with a file and a video draws both squares."
  (should (equal '(filled-square hollow-square)
                 (sort (epresent-test--indicators-on-slide "Slide with both")
                       #'string-lessp))))

(ert-deftest epresent-test-no-indicator-when-auto ()
  "EPRESENT_SHOW_AUTO suppresses the indicators entirely."
  (should (equal '()
                 (epresent-test--indicators-on-slide
                  "Slide that shows automatically"))))

(ert-deftest epresent-test-no-indicator-without-properties ()
  "A slide with no media properties draws nothing."
  (should (equal '()
                 (epresent-test--indicators-on-slide "Plain slide"))))

(ert-deftest epresent-test-indicators-respect-the-option ()
  "Nothing is drawn when `epresent-indicators' is nil."
  (let ((epresent-indicators nil))
    (should (equal '()
                   (epresent-test--indicators-on-slide "Slide with a file")))))

;;; Fontification

(ert-deftest epresent-test-fontify-creates-overlays ()
  "`epresent-fontify' completes and overlays the buffer.
This is a smoke test for the org-superstar gating and the inline-image
substitutions in `epresent-fontify', not a characterization of every
overlay it creates."
  (epresent-test-with-fixture "plain.org"
    (let ((epresent-overlays nil))
      (epresent-fontify)
      (should epresent-overlays)
      (should (cl-some (lambda (ov) (overlay-get ov 'face)) epresent-overlays)))))

(provide 'epresent-test)
;;; epresent-test.el ends here
