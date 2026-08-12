;;; orgacle-test.el --- Tests for orgacle  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run with `make test'.  Everything here must work in batch mode on a
;; machine with no window system, so nothing may create a frame, wait on
;; redisplay, or start a subprocess.

;;; Code:

(require 'ert)
(require 'org)
(require 'orgacle)

(defconst orgacle-test-fixture-directory
  (expand-file-name "fixtures"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "Directory holding the Org fixtures these tests run against.")

(defconst orgacle-test-project-directory
  (file-name-as-directory
   (expand-file-name
    ".." (file-name-directory (or load-file-name buffer-file-name))))
  "Root of the project checkout, one level above test/.")

(defmacro orgacle-test-with-fixture (name &rest body)
  "Visit fixture NAME in a temporary Org buffer and evaluate BODY there."
  (declare (indent 1) (debug (form body)))
  `(with-temp-buffer
     (insert-file-contents
      (expand-file-name ,name orgacle-test-fixture-directory))
     (let ((org-mode-hook nil))
       (org-mode))
     ,@body))

(ert-deftest orgacle-test-harness-works ()
  "The fixture directory exists and `orgacle' is loadable."
  (should (file-directory-p orgacle-test-fixture-directory))
  (should (featurep 'orgacle)))

(ert-deftest orgacle-test-loads-without-x11 ()
  "The package loads where the X pointer constants are unbound.

`x-pointer-dot' and its siblings come from term/x-win.el, so they do not
exist on a macOS, Windows, terminal or headless Emacs.  Loading the file
used to signal `void-variable' there, making the package unusable rather
than merely degraded.  Unbinding them first reproduces that Emacs."
  (let* ((default-directory orgacle-test-project-directory)
         (emacs (expand-file-name invocation-name invocation-directory))
         (output (get-buffer-create "*orgacle-test-x11*"))
         (status (call-process
                  emacs nil output nil
                  "-Q" "--batch"
                  "-l" "test/init.el"
                  "--eval" "(mapc #'makunbound '(x-pointer-dot \
x-pointer-shape x-sensitive-text-pointer-shape x-pointer-invisible))"
                  "-l" "orgacle.el")))
    (should (equal 0 status))
    (kill-buffer output)))

(ert-deftest orgacle-test-harness-prefers-newer-source ()
  "The batch harness loads the newer of orgacle.el and orgacle.elc.

`load-prefer-newer' defaults to nil, which makes `require' prefer a
stale .elc left behind by `make compile' over freshly edited source --
so a suite run without recompiling would silently test the previous
version of the code."
  (should load-prefer-newer))

;;; Keyword parsing

(ert-deftest orgacle-test-frame-level-from-keyword ()
  "`orgacle-get-frame-level' reads #+ORGACLE_FRAME_LEVEL."
  (orgacle-test-with-fixture "keywords.org"
    (should (equal 2 (orgacle-get-frame-level)))))

(ert-deftest orgacle-test-frame-level-defaults ()
  "Without the keyword, `orgacle-frame-level' is returned unchanged."
  (orgacle-test-with-fixture "plain.org"
    (should (equal orgacle-frame-level (orgacle-get-frame-level)))))

(ert-deftest orgacle-test-frame-level-ignores-restriction ()
  "The keyword is found even when the buffer is narrowed past it."
  (orgacle-test-with-fixture "keywords.org"
    (goto-char (point-max))
    (org-back-to-heading)
    (org-narrow-to-subtree)
    (should (equal 2 (orgacle-get-frame-level)))))

(ert-deftest orgacle-test-mode-line-from-keyword ()
  "`orgacle-get-mode-line' reads and parses #+ORGACLE_MODE_LINE."
  (orgacle-test-with-fixture "keywords.org"
    (should (equal '(:eval (format "slide %d" orgacle-page-number))
                   (orgacle-get-mode-line)))))

(ert-deftest orgacle-test-mode-line-defaults ()
  "Without the keyword, `orgacle-mode-line' is returned unchanged."
  (orgacle-test-with-fixture "plain.org"
    (should (equal orgacle-mode-line (orgacle-get-mode-line)))))

;;; Speaker notes

(ert-deftest orgacle-test-collect-notes-keeps-slide-headings ()
  "Every frame-level heading contributes a heading to the notes text."
  (orgacle-test-with-fixture "notes.org"
    (let ((notes (orgacle--collect-notes)))
      (should (string-match-p "^\\* First slide$" notes))
      (should (string-match-p "^\\* Second slide$" notes))
      (should (string-match-p "^\\* Third slide$" notes)))))

(ert-deftest orgacle-test-collect-notes-keeps-note-bodies ()
  "The body of each Speaker notes subtree is carried over."
  (orgacle-test-with-fixture "notes.org"
    (let ((notes (orgacle--collect-notes)))
      (should (string-match-p "One two three four five\\." notes))
      (should (string-match-p "Six seven eight\\." notes)))))

(ert-deftest orgacle-test-collect-notes-omits-slide-bodies ()
  "Text outside a Speaker notes subtree is not collected."
  (orgacle-test-with-fixture "notes.org"
    (should-not (string-match-p "Visible text" (orgacle--collect-notes)))))

(ert-deftest orgacle-test-collect-notes-repeats-the-last-heading ()
  "Current behaviour: the final heading is emitted twice.

The loop tests (< (point) (point-max)) before advancing, so on the last
heading its body runs once more with point unmoved.  P3 replaces this
loop with the slide vector; until then the duplication is pinned here so
that the lexical-binding conversion cannot change it unnoticed."
  (orgacle-test-with-fixture "notes.org"
    (should (string-match-p "\\* Third slide\n\\* Third slide"
                            (orgacle--collect-notes)))))

;;; Speaking time

(ert-deftest orgacle-test-speaker-word-count ()
  "Only words inside Speaker notes subtrees are counted.

Twelve: each subtree contributes the two words of its own heading —
`count-words' does not count the leading stars — plus five and three
words of body."
  (orgacle-test-with-fixture "notes.org"
    (should (equal 12 (orgacle--speaker-word-count)))))

(ert-deftest orgacle-test-speaker-word-count-without-notes ()
  "A buffer with no speaker notes counts zero words."
  (orgacle-test-with-fixture "plain.org"
    (should (equal 0 (orgacle--speaker-word-count)))))

(ert-deftest orgacle-test-speaking-time-scales-with-wpm ()
  "Doubling the reading speed halves the estimate."
  (let ((orgacle-wpm 150))
    (should (equal 2.0 (orgacle--speaking-time 300))))
  (let ((orgacle-wpm 300))
    (should (equal 1.0 (orgacle--speaking-time 300)))))

;;; Defect fixes

(ert-deftest orgacle-test-speaking-time-rounds-to-half-minutes ()
  "225 words at 150 wpm is a minute and a half, not one minute."
  (let ((orgacle-wpm 150))
    (should (equal 1.5 (orgacle--speaking-time 225)))
    (should (equal 2.0 (orgacle--speaking-time 300)))
    (should (equal 0.5 (orgacle--speaking-time 1)))))

(ert-deftest orgacle-test-slide-in-follows-the-option ()
  "`orgacle-slide-in' decides, and the property overrides it."
  (orgacle-test-with-fixture "plain.org"
    (let ((orgacle-slide-in nil))
      (should-not (orgacle--slide-in-p)))
    (let ((orgacle-slide-in t))
      (should (orgacle--slide-in-p)))))

(ert-deftest orgacle-test-slide-in-property-overrides ()
  "ORGACLE_SLIDE_IN turns the animation on or off for one slide."
  (orgacle-test-with-fixture "slide-in.org"
    (goto-char (point-min))
    (re-search-forward "^\\* Never$")
    (let ((orgacle-slide-in t))
      (should-not (orgacle--slide-in-p)))
    (goto-char (point-min))
    (re-search-forward "^\\* Always$")
    (let ((orgacle-slide-in nil))
      (should (orgacle--slide-in-p)))))

(ert-deftest orgacle-test-font-commands-use-real-faces ()
  "Growing and shrinking the font changes every scalable face.
Also, repeated presses of `orgacle-decrease-font' -- which mixes
absolute and relative face heights, see `orgacle--scale-font' -- must
never signal and must never drive a height to zero or below."
  (let ((original (mapcar (lambda (face)
                            (cons face (face-attribute face :height)))
                          orgacle-scalable-faces)))
    (unwind-protect
        (progn
          ;; one press visibly changes every face
          (orgacle-increase-font)
          (dolist (face orgacle-scalable-faces)
            (should-not (equal (face-attribute face :height)
                               (cdr (assq face original)))))
          (let ((after-grow (mapcar (lambda (face)
                                     (cons face (face-attribute face :height)))
                                   orgacle-scalable-faces)))
            ;; the opposite press visibly changes every face again
            (orgacle-decrease-font)
            (dolist (face orgacle-scalable-faces)
              (should-not (equal (face-attribute face :height)
                                 (cdr (assq face after-grow))))))
          ;; repeated presses never signal and never reach zero or below
          (dotimes (_ 10)
            (should (progn (orgacle-decrease-font) t)))
          (dolist (face orgacle-scalable-faces)
            (should (> (face-attribute face :height) 0))))
      ;; restore the faces so later tests see the defface heights
      (dolist (pair original)
        (set-face-attribute (car pair) nil :height (cdr pair))))))

(ert-deftest orgacle-test-export-includes-properties-by-default ()
  "The backend exports property drawers without being asked.

`org-export-with-properties' defaults to nil, which discarded the very
drawers this backend exists to translate."
  (orgacle-test-with-fixture "export.org"
    (should (string-match-p
             "\\\\includegraphics"
             (org-export-as 'orgacle nil nil t)))))

;;; LaTeX export backend

(defun orgacle-test--export-fixture (name)
  "Export fixture NAME through the orgacle backend and return the LaTeX.
`:with-properties' has to be forced on: `org-export-with-properties'
defaults to nil, and without it Org discards property drawers before
the backend ever sees them, so the translator never runs.  Task 9 makes
the backend default it to t; this helper keeps the tests honest either
way."
  (orgacle-test-with-fixture name
    (org-export-as 'orgacle nil nil t '(:with-properties t))))

(ert-deftest orgacle-test-export-emits-includegraphics ()
  "ORGACLE_SHOW_FILE becomes an \\includegraphics with the given width."
  (let ((latex (orgacle-test--export-fixture "export.org")))
    (should (string-match-p
             "\\\\includegraphics\\[width=0\\.8\\\\textwidth,page=1\\]{figure\\.pdf}"
             latex))))

(ert-deftest orgacle-test-export-strips-org-link-brackets ()
  "A filename written as an Org link loses its brackets."
  (let ((latex (orgacle-test--export-fixture "export.org")))
    (should-not (string-match-p "{\\[\\[figure" latex))))

(ert-deftest orgacle-test-export-honours-page-list ()
  "ORGACLE_SHOW_PAGES emits one \\includegraphics per page."
  (let ((latex (orgacle-test--export-fixture "export.org")))
    (should (string-match-p "page=1\\]{figure\\.pdf}" latex))
    (should (string-match-p "page=3\\]{figure\\.pdf}" latex))))

(ert-deftest orgacle-test-export-names-videos ()
  "ORGACLE_VIDEO_ALT becomes a bracketed note naming the file."
  (let ((latex (orgacle-test--export-fixture "export.org")))
    (should (string-match-p "\\[ Video: demo\\.mp4 \\]" latex))))

(ert-deftest orgacle-test-export-defaults-width ()
  "A drawer with no ORGACLE_SHOW_WIDTH uses half the text width."
  (let ((latex (orgacle-test--export-fixture "export.org")))
    (should (string-match-p "width=0\\.5\\\\textwidth" latex))))

(ert-deftest orgacle-test-export-inlines-org-files ()
  "An ORGACLE_SHOW_FILE naming an Org file is converted and inlined.

This branch was uncovered when a lexical-binding conversion silently
broke it, so it is pinned here."
  (let ((latex (orgacle-test--export-fixture "export-include.org")))
    (should (string-match-p "Included heading" latex))
    (should (string-match-p "\\\\textbf{bold}" latex))))

;;; Fringe indicators

(defun orgacle-test--indicators-on-slide (heading)
  "Narrow to HEADING in the indicators fixture and return the fringe bitmaps.
The result is a list of symbols such as `filled-square', in no
particular order."
  (orgacle-test-with-fixture "indicators.org"
    (goto-char (point-min))
    (re-search-forward (concat "^\\* " (regexp-quote heading) "$"))
    (org-narrow-to-subtree)
    (let ((orgacle-fringe-overlays nil))
      (orgacle-show-indicators-maybe)
      (prog1 (mapcar (lambda (ov)
                       (nth 1 (get-text-property
                               0 'display (overlay-get ov 'before-string))))
                     orgacle-fringe-overlays)
        (mapc #'delete-overlay orgacle-fringe-overlays)))))

(ert-deftest orgacle-test-indicator-for-file ()
  "ORGACLE_SHOW_FILE draws a filled square."
  (should (equal '(filled-square)
                 (orgacle-test--indicators-on-slide "Slide with a file"))))

(ert-deftest orgacle-test-indicator-for-video ()
  "ORGACLE_SHOW_VIDEO draws a hollow square."
  (should (equal '(hollow-square)
                 (orgacle-test--indicators-on-slide "Slide with a video"))))

(ert-deftest orgacle-test-indicator-for-both ()
  "A slide with a file and a video draws both squares."
  (should (equal '(filled-square hollow-square)
                 (sort (orgacle-test--indicators-on-slide "Slide with both")
                       #'string-lessp))))

(ert-deftest orgacle-test-no-indicator-when-auto ()
  "ORGACLE_SHOW_AUTO suppresses the indicators entirely."
  (should (equal '()
                 (orgacle-test--indicators-on-slide
                  "Slide that shows automatically"))))

(ert-deftest orgacle-test-no-indicator-without-properties ()
  "A slide with no media properties draws nothing."
  (should (equal '()
                 (orgacle-test--indicators-on-slide "Plain slide"))))

(ert-deftest orgacle-test-indicators-respect-the-option ()
  "Nothing is drawn when `orgacle-indicators' is nil."
  (let ((orgacle-indicators nil))
    (should (equal '()
                   (orgacle-test--indicators-on-slide "Slide with a file")))))

;;; Fontification

(ert-deftest orgacle-test-fontify-creates-overlays ()
  "`orgacle-fontify' completes and overlays the buffer.
This is a smoke test for the org-superstar gating and the inline-image
substitutions in `orgacle-fontify', not a characterization of every
overlay it creates."
  (orgacle-test-with-fixture "plain.org"
    (let ((orgacle-overlays nil))
      (orgacle-fontify)
      (should orgacle-overlays)
      (should (cl-some (lambda (ov) (overlay-get ov 'face)) orgacle-overlays)))))

(provide 'orgacle-test)
;;; orgacle-test.el ends here
