;;; orgacle-test.el --- Tests for orgacle  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run with `make test'.  Everything here must work in batch mode on a
;; machine with no window system, so nothing may create a frame, wait on
;; redisplay, or start a subprocess.

;;; Code:

(require 'ert)
(require 'org)
(require 'orgacle)
(require 'ox-orgacle)

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

;;; Video

(ert-deftest orgacle-test-video-player-is-detected ()
  "An unrecognised `orgacle-video-player' name is reported, not run.
This exercises the unsupported-name branch of `orgacle--video-command';
see `orgacle-test-video-player-executable-not-found' for a recognised
player whose executable is missing instead."
  (let ((orgacle-video-player "definitely-not-a-real-player"))
    (should-error (orgacle--video-command "film.mp4" nil) :type 'user-error)))

(ert-deftest orgacle-test-video-player-executable-not-found ()
  "A configured, recognised player that is not installed is reported,
not run.
`executable-find' is stubbed so this characterizes the missing-binary
branch without depending on whether mplayer happens to be installed on
the machine running the suite."
  (let ((orgacle-video-player "mplayer"))
    (cl-letf (((symbol-function 'executable-find) (lambda (&rest _) nil)))
      (should-error (orgacle--video-command "film.mp4" nil) :type 'user-error))))

(ert-deftest orgacle-test-video-command-quotes-its-filename ()
  "A filename with a space survives as one argument.

`executable-find' is stubbed so this characterizes only the quoting,
not whether mplayer happens to be installed on the machine running
the suite.  `shell-quote-argument' backslash-escapes special
characters rather than wrapping the whole argument in quotes on a
POSIX shell -- so pinning its literal output, whatever that is on the
running platform, is what actually characterizes \"the filename is
quoted\" portably; a fixed quote-style regex would not match what it
really produces."
  (let ((orgacle-video-player "mplayer"))
    (cl-letf (((symbol-function 'executable-find) (lambda (&rest _) "/usr/bin/mplayer")))
      (should (string-suffix-p (shell-quote-argument "my film.mp4")
                               (orgacle--video-command "my film.mp4" nil))))))

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

;;; Migration

(ert-deftest orgacle-test-migrate-renames-properties ()
  "Drawer properties and buffer keywords are both converted."
  (orgacle-test-with-fixture "legacy.org"
    (orgacle-migrate-buffer)
    (should (string-match-p "^:ORGACLE_SHOW_FILE: figure\\.pdf$" (buffer-string)))
    (should (string-match-p "^#\\+ORGACLE_FRAME_LEVEL: 2$" (buffer-string)))))

(ert-deftest orgacle-test-migrate-reports-a-count ()
  "The number of substitutions is returned."
  (orgacle-test-with-fixture "legacy.org"
    ;; two drawer properties, one keyword, one prose mention
    (should (equal 4 (orgacle-migrate-buffer)))))

(ert-deftest orgacle-test-migrate-leaves-nothing-behind ()
  "No EPRESENT_ name survives migration."
  (orgacle-test-with-fixture "legacy.org"
    (orgacle-migrate-buffer)
    (should-not (string-match-p "EPRESENT_" (buffer-string)))))

(ert-deftest orgacle-test-migrate-is-idempotent ()
  "Running it twice changes nothing the second time."
  (orgacle-test-with-fixture "legacy.org"
    (should (equal 4 (orgacle-migrate-buffer)))
    (let ((once (buffer-string)))
      (should (equal 0 (orgacle-migrate-buffer)))
      (should (equal once (buffer-string))))))

(ert-deftest orgacle-test-migrate-honours-an-active-region ()
  "Called interactively with a region active, only that region converts."
  (orgacle-test-with-fixture "legacy.org"
    (goto-char (point-min))
    (re-search-forward "^:PROPERTIES:$")
    (let ((transient-mark-mode t))
      (push-mark (match-beginning 0) t t)
      (re-search-forward "^:END:$")
      (goto-char (match-end 0))
      (call-interactively #'orgacle-migrate-buffer))
    ;; the drawer converted, the keyword above it did not
    (should (string-match-p "^:ORGACLE_SHOW_FILE:" (buffer-string)))
    (should (string-match-p "^#\\+EPRESENT_FRAME_LEVEL:" (buffer-string)))))

(defun orgacle-test--migrate-file-fixture-copy ()
  "Copy the legacy fixture into a fresh temp file and return its name.
The caller is responsible for deleting the file and killing any buffer
left visiting it."
  (let ((temp (make-temp-file "orgacle-test-migrate" nil ".org")))
    (copy-file (expand-file-name "legacy.org" orgacle-test-fixture-directory)
               temp t)
    temp))

(defmacro orgacle-test-with-migrate-file-fixture (file-var &rest body)
  "Bind FILE-VAR to a temp copy of legacy.org and evaluate BODY.
Deletes the temp file and kills any buffer left visiting it
afterwards, even if BODY signals."
  (declare (indent 1) (debug (symbolp body)))
  `(let ((,file-var (orgacle-test--migrate-file-fixture-copy)))
     (unwind-protect
         (progn ,@body)
       (let ((buf (find-buffer-visiting ,file-var)))
         (when buf (kill-buffer buf)))
       (delete-file ,file-var))))

(ert-deftest orgacle-test-migrate-file-converts-file-on-disk ()
  "Migrating a file rewrites its contents on disk, not just in memory."
  (orgacle-test-with-migrate-file-fixture file
    (should (equal 4 (orgacle-migrate-file file)))
    (with-temp-buffer
      (insert-file-contents file)
      (should-not (string-match-p "EPRESENT_" (buffer-string)))
      (should (string-match-p "^:ORGACLE_SHOW_FILE: figure\\.pdf$"
                               (buffer-string))))))

(ert-deftest orgacle-test-migrate-file-widens-a-narrowed-open-buffer ()
  "Migrating a file converts the whole file, even when a buffer already
visiting it is narrowed to less than the whole file.

Regression test: `find-file-noselect' returns an already-open buffer
as-is, narrowing and all.  Migrating through a narrowed buffer used to
convert only the accessible portion while reporting the file fully
migrated, leaving EPRESENT_ names on disk outside the narrowed region."
  (orgacle-test-with-migrate-file-fixture file
    (find-file file)
    (goto-char (point-min))
    (re-search-forward "^\\* Old slide")
    (org-narrow-to-subtree)
    (should (buffer-narrowed-p))
    ;; the frame-level keyword sits before the narrowed subtree
    (should-not (string-match-p "EPRESENT_FRAME_LEVEL"
                                 (buffer-substring (point-min) (point-max))))
    (orgacle-migrate-file file)
    (with-temp-buffer
      (insert-file-contents file)
      (should-not (string-match-p "EPRESENT_" (buffer-string))))))

;;; Page hook

(ert-deftest orgacle-test-page-hook-runs-on-display ()
  "Displaying a slide runs `orgacle-page-hook'."
  (orgacle-test-with-fixture "plain.org"
    (let* ((ran 0)
           (orgacle-page-hook (list (lambda () (setq ran (1+ ran))))))
      ;; `point-min' sits on the #+TITLE line, before the first
      ;; headline, where `orgacle-current-page' only folds a TOC and
      ;; never runs the hook; go to the first slide so this exercises
      ;; the branch that actually displays one.
      (goto-char (point-min))
      (re-search-forward "^\\* First slide")
      (orgacle-current-page)
      (should (= ran 1)))))

(ert-deftest orgacle-test-page-hook-survives-a-failing-member ()
  "A member that signals does not stop the others or the presentation."
  (orgacle-test-with-fixture "plain.org"
    (let* ((ran nil)
           (orgacle-page-hook
            (list (lambda () (error "Deliberate failure"))
                  (lambda () (setq ran t)))))
      (goto-char (point-min))
      (re-search-forward "^\\* First slide")
      (should (progn (orgacle-current-page) t))
      (should ran))))

(ert-deftest orgacle-test-page-hook-order-is-file-slide-in-indicators-notes ()
  "The real, global `orgacle-page-hook' runs file, slide-in, indicators,
then notes, in that order -- not merely some order the four `add-hook'
calls happen to produce.  File-before-indicators is the part that is
not cosmetic: `orgacle-show-file' calls `orgacle-clean-fringe-overlays',
so if indicators ran first, `orgacle-show-file' would wipe the fringe
overlays `orgacle-show-indicators-maybe' had just drawn.  The other new
tests in this section let-bind `orgacle-page-hook' away to isolate the
runner, so this is the only test that looks at the real, default
value."
  (should (equal '(orgacle-show-file-auto orgacle-slide-in-effect
                    orgacle-show-indicators-maybe orgacle-position-notes)
                 (default-value 'orgacle-page-hook))))

;;; Session state

(ert-deftest orgacle-test-user-state-round-trips ()
  "Saving then restoring leaves the user's Org settings as they were."
  (let ((org-src-fontify-natively 'sentinel)
        (org-hide-emphasis-markers 'sentinel)
        (org-pretty-entities 'sentinel))
    (orgacle--save-user-state)
    (setq org-src-fontify-natively t
          org-hide-emphasis-markers t
          org-pretty-entities t)
    (orgacle--restore-user-state)
    (should (eq org-src-fontify-natively 'sentinel))
    (should (eq org-hide-emphasis-markers 'sentinel))
    (should (eq org-pretty-entities 'sentinel))))

(ert-deftest orgacle-test-quit-is-idempotent ()
  "Quitting when no presentation is running does nothing and does not signal."
  (should (progn (orgacle-quit) t))
  (should (progn (orgacle-quit) t)))

(ert-deftest orgacle-test-mode-enters ()
  "Entering `orgacle-mode' on a plain buffer completes without signaling.

A smoke test, not a characterization of everything the mode does: it
exists because nothing in the suite called `orgacle-mode' at all,
which let a byte-compile-only crash in its display-table handling
reach users unnoticed.  Batch mode has no frame of its own, so
`orgacle--frame' stays nil here; `set-face-attribute' with a nil frame
argument means the selected frame, which exists even in batch, so the
mode's frame-facing calls do not need a real one to complete.

Quits at the end, in an `unwind-protect': other tests rely on
`orgacle--save-user-state' having nothing already saved when they
start, and since the re-entrancy fix that condition is sticky rather
than clobbered on every call -- see the re-entrancy tests below."
  (orgacle-test-with-fixture "plain.org"
    (unwind-protect
        (progn
          (orgacle-mode)
          (should (eq major-mode 'orgacle-mode)))
      (orgacle-quit))))

;;; Re-entrant orgacle-mode

(ert-deftest orgacle-test-second-entry-preserves-saved-variables ()
  "Entering `orgacle-mode' twice without an intervening `orgacle-quit'
must not let the second entry's `orgacle--save-user-state' overwrite the
user's original values with the presentation's own -- the first save has
to win, so that quitting still restores what the user actually had.

This reproduces without needing two real frames: killing the
presentation frame with the window manager instead of pressing q, or
running `orgacle-run' a second time from a different Org buffer, both
leave `orgacle-mode' entered a second time with no intervening
`orgacle-quit' in between -- `orgacle-run' only inspects the *current*
buffer's major mode, so neither path is exotic."
  (orgacle-test-with-fixture "plain.org"
    (let ((org-src-fontify-natively 'user)
          (org-hide-emphasis-markers 'user)
          (org-pretty-entities 'user)
          (org-fontify-quote-and-verse-blocks 'user))
      (orgacle-mode)
      (orgacle-mode)
      (orgacle-quit)
      (should (eq org-src-fontify-natively 'user))
      (should (eq org-hide-emphasis-markers 'user))
      (should (eq org-pretty-entities 'user))
      (should (eq org-fontify-quote-and-verse-blocks 'user)))))

(ert-deftest orgacle-test-second-entry-preserves-outline-ellipsis ()
  "The same re-entrancy protection covers the outline-ellipsis
display-table slot, which has exactly the same shape as the tracked
variables above but cannot join `orgacle-saved-variables' because it is
not a variable.  Without the guard, the second entry captures the
presentation's own `[32]' as though it were the user's ellipsis, and
quitting leaves the invisible space in place instead of restoring it."
  (orgacle-test-with-fixture "plain.org"
    (unless (char-table-p standard-display-table)
      (setq standard-display-table (make-display-table)))
    (set-display-table-slot standard-display-table 'selective-display "user-ellipsis")
    (orgacle-mode)
    (orgacle-mode)
    (orgacle-quit)
    (should (equal (display-table-slot standard-display-table 'selective-display)
                   "user-ellipsis"))))

(provide 'orgacle-test)
;;; orgacle-test.el ends here
