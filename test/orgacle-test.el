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

;;; Slide vector

(ert-deftest orgacle-test-build-slides-counts-real-slides ()
  "Title page, hidden and speaker-notes headings are not slides."
  (orgacle-test-with-fixture "slides.org"
    (should (= 3 (length (orgacle--build-slides))))))

(ert-deftest orgacle-test-build-slides-are-in-order ()
  "The vector is in buffer order and its markers point at headings."
  (orgacle-test-with-fixture "slides.org"
    (let ((slides (orgacle--build-slides)))
      (should (equal '("First slide" "Second slide" "Third slide")
                     (mapcar (lambda (m)
                               (save-excursion
                                 (goto-char m)
                                 (org-entry-get nil "ITEM")))
                             (append slides nil)))))))

(ert-deftest orgacle-test-build-slides-respects-frame-level ()
  "With a frame level of 2, the second-level headings are the slides."
  (orgacle-test-with-fixture "slides.org"
    (let ((orgacle-frame-level 2))
      (should (= 1 (length (orgacle--build-slides)))))))

(ert-deftest orgacle-test-build-slides-on-a-plain-file ()
  "A file with no exclusions yields one slide per top-level heading."
  (orgacle-test-with-fixture "plain.org"
    (should (= 2 (length (orgacle--build-slides))))))

;;; Speaker notes

(ert-deftest orgacle-test-collect-notes-keeps-slide-headings ()
  "Every frame-level heading contributes a heading to the notes text."
  (orgacle-test-with-fixture "notes.org"
    (orgacle--start-slides)
    (let ((notes (orgacle--collect-notes)))
      (should (string-match-p "^\\* First slide$" notes))
      (should (string-match-p "^\\* Second slide$" notes))
      (should (string-match-p "^\\* Third slide$" notes)))))

(ert-deftest orgacle-test-collect-notes-keeps-note-bodies ()
  "The body of each Speaker notes subtree is carried over."
  (orgacle-test-with-fixture "notes.org"
    (orgacle--start-slides)
    (let ((notes (orgacle--collect-notes)))
      (should (string-match-p "One two three four five\\." notes))
      (should (string-match-p "Six seven eight\\." notes)))))

(ert-deftest orgacle-test-collect-notes-omits-slide-bodies ()
  "Text outside a Speaker notes subtree is not collected."
  (orgacle-test-with-fixture "notes.org"
    (orgacle--start-slides)
    (should-not (string-match-p "Visible text" (orgacle--collect-notes)))))

(ert-deftest orgacle-test-collect-notes-emits-the-last-heading-once ()
  "The final heading is emitted exactly once, not twice.

`orgacle--collect-notes' now walks the fixed-length slides slot
instead of a heading-by-heading loop that tested \(< (point)
\(point-max)) before advancing and so ran its body once more on the
last heading.  This test replaces
`orgacle-test-collect-notes-repeats-the-last-heading', which pinned
that duplication in P0 specifically so this phase could remove it; see
the P3 task 3 report for why changing a pinned characterization test
is correct here."
  (orgacle-test-with-fixture "notes.org"
    (orgacle--start-slides)
    (let ((notes (orgacle--collect-notes)))
      (should (string-match-p "\\* Third slide" notes))
      (should-not (string-match-p "\\* Third slide\n\\* Third slide" notes)))))

(ert-deftest orgacle-test-collect-notes-includes-a-todo-marked-heading ()
  "A TODO-marked \"Speaker notes\" heading still reaches the notes buffer.

`org-entry-get's ITEM value strips the TODO keyword, so
\"** TODO Speaker notes\" is exactly what `orgacle--slide-p',
`orgacle-mode's hiding loop and `orgacle--speaker-word-count' already
treat as a speaker-notes heading; before this fix
`orgacle--collect-notes-segments' instead matched the raw heading line
against a literal regexp, which \"** TODO Speaker notes\" never
matches, so its body was silently dropped from the notes buffer."
  (orgacle-test-with-fixture "notes-todo-tag.org"
    (orgacle--start-slides)
    (should (string-match-p "TODO notes body" (orgacle--collect-notes)))))

(ert-deftest orgacle-test-collect-notes-includes-a-tagged-heading ()
  "A tagged \"Speaker notes\" heading still reaches the notes buffer.

Same defect as the TODO-marked case, for a heading of the form
\"** Speaker notes :notes:\": `org-entry-get's ITEM value strips the
tags too, so the fixed regexp-free scan matches it, where the old
raw-line regexp did not."
  (orgacle-test-with-fixture "notes-todo-tag.org"
    (orgacle--start-slides)
    (should (string-match-p "Tagged notes body" (orgacle--collect-notes)))))

;;; Notes by index

(defmacro orgacle-test-with-notes-buffer (&rest body)
  "Run BODY with a scratch notes buffer shown in the selected window.
Requires the session's slides to already be built (`orgacle--start-slides'
having run).  Builds a fresh notes buffer and marker vector with
`orgacle--build-notes-buffer' into the current session's notes-buffer
and notes-markers slots, saving whatever was there before and
restoring it -- along with the window configuration, and killing the
scratch buffer -- afterwards, regardless of how BODY exits, so a notes
test cannot leak a live buffer or a repointed window into whatever
test happens to run next in the same batch process.  The slots are
restored by value rather than by dynamically let-binding a variable,
because they are now slots of the single, session-wide
`orgacle--session' struct rather than variables of their own; this is
also why `orgacle-refresh', called from within BODY and free to replace
the notes-buffer slot with a new buffer object, still gets that
replacement cleaned up here, not the original."
  (declare (indent 0) (debug (body)))
  `(let* ((session (orgacle--session-ensure))
          (orgacle-test--saved-notes-buffer (orgacle--session-notes-buffer session))
          (orgacle-test--saved-notes-markers (orgacle--session-notes-markers session)))
     (setf (orgacle--session-notes-buffer session) nil)
     (setf (orgacle--session-notes-markers session) nil)
     (orgacle--build-notes-buffer)
     (unwind-protect
         (save-window-excursion
           (set-window-buffer (selected-window)
                               (orgacle--session-notes-buffer session))
           ,@body)
       (when (buffer-live-p (orgacle--session-notes-buffer session))
         (kill-buffer (orgacle--session-notes-buffer session)))
       (setf (orgacle--session-notes-buffer session)
             orgacle-test--saved-notes-buffer)
       (setf (orgacle--session-notes-markers session)
             orgacle-test--saved-notes-markers))))

(ert-deftest orgacle-test-position-notes-disambiguates-same-titled-slides ()
  "Two slides with the same title each keep their own notes block.

A text search for \"Results\" would always land on the first slide's
notes; `orgacle-position-notes' instead jumps by the session's index
slot, so the second \"Results\" slide's notes are the second block,
not the first."
  (orgacle-test-with-fixture "notes-duplicate-titles.org"
    (orgacle--start-slides)
    (orgacle-test-with-notes-buffer
      (setf (orgacle--session-index (orgacle--session-ensure)) 1)
      (orgacle-position-notes)
      (with-current-buffer (orgacle--session-notes-buffer (orgacle--session-ensure))
        (should (string-match-p "Second results block" (buffer-string)))
        (should-not (string-match-p "First results block" (buffer-string)))))))

(ert-deftest orgacle-test-position-notes-first-slide ()
  "The first slide's notes are still reachable by index."
  (orgacle-test-with-fixture "notes-duplicate-titles.org"
    (orgacle--start-slides)
    (orgacle-test-with-notes-buffer
      (setf (orgacle--session-index (orgacle--session-ensure)) 0)
      (orgacle-position-notes)
      (with-current-buffer (orgacle--session-notes-buffer (orgacle--session-ensure))
        (should (string-match-p "First results block" (buffer-string)))
        (should-not (string-match-p "Second results block" (buffer-string)))))))

(ert-deftest orgacle-test-position-notes-without-a-notes-buffer-does-not-signal ()
  "With no notes buffer, positioning is a no-op, not an error."
  (orgacle-test-with-fixture "plain.org"
    (orgacle--start-slides)
    (let ((session (orgacle--session-ensure)))
      (setf (orgacle--session-notes-buffer session) nil)
      (setf (orgacle--session-notes-markers session) nil))
    (should (progn (orgacle-position-notes) t))))

(ert-deftest orgacle-test-position-notes-with-no-speaker-notes-does-not-signal ()
  "A deck with no Speaker notes subtrees anywhere still navigates."
  (orgacle-test-with-fixture "plain.org"
    (orgacle--start-slides)
    (orgacle-test-with-notes-buffer
      (dotimes (i (length (orgacle--session-slides (orgacle--session-ensure))))
        (setf (orgacle--session-index (orgacle--session-ensure)) i)
        (should (progn (orgacle-position-notes) t))))))

(ert-deftest orgacle-test-position-notes-stale-index-does-not-signal ()
  "An index past the end of the notes-markers slot does not signal.

`orgacle-refresh' now keeps a live notes buffer from going stale this
way in the first place (see
`orgacle-test-refresh-rebuilds-the-notes-buffer'), but the guard in
`orgacle-position-notes' stays regardless, as defense against any
other way the two vectors could end up out of step."
  (orgacle-test-with-fixture "notes-duplicate-titles.org"
    (orgacle--start-slides)
    (orgacle-test-with-notes-buffer
      (setf (orgacle--session-index (orgacle--session-ensure))
            (length (orgacle--session-notes-markers (orgacle--session-ensure))))
      (should (progn (orgacle-position-notes) t)))))

(ert-deftest orgacle-test-notes-markers-count-matches-slides-despite-body-content ()
  "Marker count always equals slide count, by construction, not inference.

The notes-markers slot used to be built by re-scanning the finished
notes buffer for lines that look like a level-1 heading, trusting the
count and order to match the slides slot.  It is now recorded at the
moment each slide's segment is inserted, so the two sequences share a
construction step instead of being linked by an inference.

This fixture's first slide has, inside an example block in its own
Speaker notes, a line that reads like a heading.  Org's outline
scanning is line-based rather than block-aware, so that line is not
actually exempt the way block-fenced content might be assumed to be:
the slides slot has three entries here, not two, because the line
really is treated as its own (degenerate) slide -- confirmed by the
first assertion below.  That is a pre-existing, more general
limitation of line-based Org outline parsing, present before this
task and not something its fix changes or could change.  What this
test actually verifies is the fix's own guarantee, which holds
regardless of that limitation: the marker count tracks whatever the
slides slot turns out to be, exactly, with no separate scan of the
notes buffer that could disagree with it, and the last index still
resolves to the last slide's own content, not a neighbour's."
  (orgacle-test-with-fixture "notes-example-block.org"
    (orgacle--start-slides)
    (should (= 3 (length (orgacle--session-slides (orgacle--session-ensure)))))
    (orgacle-test-with-notes-buffer
      (should (= (length (orgacle--session-slides (orgacle--session-ensure)))
                 (length (orgacle--session-notes-markers (orgacle--session-ensure)))))
      (setf (orgacle--session-index (orgacle--session-ensure))
            (1- (length (orgacle--session-slides (orgacle--session-ensure)))))
      (orgacle-position-notes)
      (with-current-buffer (orgacle--session-notes-buffer (orgacle--session-ensure))
        (should (string-match-p "Two's real notes" (buffer-string)))
        (should-not (string-match-p "One's real notes" (buffer-string)))))))

(ert-deftest orgacle-test-refresh-rebuilds-the-notes-buffer ()
  "A live notes buffer is rebuilt on refresh, not left stale.

Without this, `orgacle-refresh' rebuilds the slides slot and
re-derives the index slot, but the notes-markers slot keeps pointing
at the deck as it stood when the notes buffer was last built.
Inserting a slide before the current one and refreshing then leaves
the re-derived index pointing at a different slide in the stale
vector -- silently the wrong slide's notes, not a signal, since the
stale vector is still long enough for the guard in
`orgacle-position-notes' to pass."
  (orgacle-test-with-fixture "notes-refresh.org"
    (orgacle--start-slides)
    (orgacle-test-with-notes-buffer
      (orgacle-top)
      (orgacle-next-page)                ; "Beta", the second slide
      (should (equal "Beta" (org-entry-get nil "ITEM")))
      (with-current-buffer (orgacle--session-notes-buffer (orgacle--session-ensure))
        (should (string-match-p "Beta notes" (buffer-string))))
      ;; simulate a live edit: insert a new slide right before "Beta"
      (widen)
      (goto-char (point-min))
      (re-search-forward "^\\* Beta")
      (org-back-to-heading)
      (insert "* Zero\n\nInserted before Beta.\n\n")
      ;; back to where the presenter was actually looking
      (goto-char (point-min))
      (re-search-forward "^\\* Beta")
      (orgacle-refresh)
      ;; re-navigate to wherever refresh put the presenter -- this is
      ;; what re-triggers `orgacle-position-notes' via the page hook
      (orgacle-jump-to-page (1+ (orgacle--session-index (orgacle--session-ensure))))
      (should (equal "Beta" (org-entry-get nil "ITEM")))
      (with-current-buffer (orgacle--session-notes-buffer (orgacle--session-ensure))
        (should (string-match-p "Beta notes" (buffer-string)))
        (should-not (string-match-p "Alpha notes\\|Gamma notes"
                                     (buffer-string)))))))

(ert-deftest orgacle-test-refresh-without-navigating-keeps-the-current-slides-notes ()
  "Refreshing alone, with no navigation afterwards, does not rewind the
notes screen to slide 1.

`orgacle--build-notes-buffer' used to always narrow the rebuilt notes
buffer to `point-min' -- the first slide's segment -- regardless of
which slide was actually current, and `orgacle-refresh' does not run
the page hook itself, so nothing put the notes screen back.  This fires
on r, on g, on exiting `orgacle-edit-text', and -- through the global
`org-babel-after-execute-hook' -- on every `x' that runs a source
block, which is routine mid-talk: the presenter is left looking at
\"Beta\" while their second screen silently shows \"Alpha\" again.
`orgacle-test-refresh-rebuilds-the-notes-buffer' above misses this
because it calls `orgacle-jump-to-page' after refreshing, which
re-triggers `orgacle-position-notes' via the page hook and papers over
exactly this bug; this test refreshes and stops there."
  (orgacle-test-with-fixture "notes-refresh.org"
    (orgacle--start-slides)
    (orgacle-test-with-notes-buffer
      (orgacle-top)
      (orgacle-next-page)                ; "Beta", the second slide
      (should (equal "Beta" (org-entry-get nil "ITEM")))
      (with-current-buffer (orgacle--session-notes-buffer (orgacle--session-ensure))
        (should (string-match-p "Beta notes" (buffer-string))))
      (orgacle-refresh)
      ;; no navigation after refresh -- still on "Beta"
      (should (equal "Beta" (org-entry-get nil "ITEM")))
      (should (= 1 (orgacle--session-index (orgacle--session-ensure))))
      (with-current-buffer (orgacle--session-notes-buffer (orgacle--session-ensure))
        (should (string-match-p "Beta notes" (buffer-string)))
        (should-not (string-match-p "Alpha notes\\|Gamma notes"
                                     (buffer-string)))))))

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

(defun orgacle-test--signal-deliberate-failure ()
  "Signal an error, for use as a deliberately failing page-hook member."
  (error "Deliberate failure"))

(ert-deftest orgacle-test-page-hook-logs-a-failing-member ()
  "A failing member leaves a log entry naming the function, the
1-based slide number shown on screen, and the error, in
`orgacle--log-buffer-name', and the remaining members still run."
  (orgacle-test-with-fixture "slides.org"
    (orgacle--start-slides)
    (orgacle-next-page) ; index 1, page number 2, "Second slide"
    (let* ((ran nil)
           (orgacle-page-hook
            (list #'orgacle-test--signal-deliberate-failure
                  (lambda () (setq ran t)))))
      (when (get-buffer orgacle--log-buffer-name)
        (kill-buffer orgacle--log-buffer-name))
      (unwind-protect
          (progn
            (orgacle-current-page)
            (should ran)
            (with-current-buffer (get-buffer orgacle--log-buffer-name)
              (let ((contents (buffer-string)))
                (should (string-match-p
                         "orgacle-test--signal-deliberate-failure" contents))
                (should (= 2 orgacle-page-number))
                (should (string-match-p "\\bslide 2\\b" contents))
                (should (string-match-p "Deliberate failure" contents)))))
        (when (get-buffer orgacle--log-buffer-name)
          (kill-buffer orgacle--log-buffer-name))))))

(ert-deftest orgacle-test-page-hook-logs-unknown-slide-with-no-deck ()
  "The log says \"slide unknown\", rather than guessing a number or
signalling, when a failing member runs before any slide deck has been
built -- `orgacle--session-index' is nil then, the same state a fresh
session starts in before `orgacle--start-slides' has ever run."
  (orgacle-test-with-fixture "plain.org"
    (let* ((session (orgacle--session-ensure))
           (saved-index (orgacle--session-index session))
           (orgacle-page-hook
            (list (lambda () (error "Deliberate failure")))))
      (setf (orgacle--session-index session) nil)
      (when (get-buffer orgacle--log-buffer-name)
        (kill-buffer orgacle--log-buffer-name))
      (unwind-protect
          (progn
            (goto-char (point-min))
            (re-search-forward "^\\* First slide")
            (orgacle-current-page)
            (with-current-buffer (get-buffer orgacle--log-buffer-name)
              (should (string-match-p "\\bslide unknown\\b" (buffer-string)))))
        (setf (orgacle--session-index session) saved-index)
        (when (get-buffer orgacle--log-buffer-name)
          (kill-buffer orgacle--log-buffer-name))))))

(ert-deftest orgacle-test-page-hook-log-buffer-stays-hidden ()
  "A failing page-hook member never pops `orgacle--log-buffer-name' up
onto the screen; it is for reading after the presentation, not during
it."
  (orgacle-test-with-fixture "slides.org"
    (orgacle--start-slides)
    (orgacle-next-page) ; a real slide, so the page hook actually runs
    (let ((orgacle-page-hook
           (list (lambda () (error "Deliberate failure")))))
      (when (get-buffer orgacle--log-buffer-name)
        (kill-buffer orgacle--log-buffer-name))
      (unwind-protect
          (progn
            (orgacle-current-page)
            (should (get-buffer orgacle--log-buffer-name))
            (should-not (get-buffer-window orgacle--log-buffer-name t)))
        (when (get-buffer orgacle--log-buffer-name)
          (kill-buffer orgacle--log-buffer-name))))))

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

;;; Navigation

(ert-deftest orgacle-test-nav-starts-at-the-first-real-slide ()
  "A leading title page is skipped without recursion."
  (orgacle-test-with-fixture "slides.org"
    (orgacle--start-slides)
    (orgacle-top)
    (should (equal "First slide" (org-entry-get nil "ITEM")))
    (should (= 1 orgacle-page-number))))

(ert-deftest orgacle-test-nav-page-number-round-trips ()
  "Forward then back returns both the slide and its number."
  (orgacle-test-with-fixture "slides.org"
    (orgacle--start-slides)
    (orgacle-top)
    (orgacle-next-page)
    (orgacle-next-page)
    (should (= 3 orgacle-page-number))
    (orgacle-previous-page)
    (should (= 2 orgacle-page-number))
    (should (equal "Second slide" (org-entry-get nil "ITEM")))))

(ert-deftest orgacle-test-nav-stops-at-the-ends ()
  "Past the last slide and before the first, nothing moves and nothing signals."
  (orgacle-test-with-fixture "slides.org"
    (orgacle--start-slides)
    (orgacle-top)
    (orgacle-previous-page)
    (should (= 1 orgacle-page-number))
    (dotimes (_ 10) (orgacle-next-page))
    (should (= 3 orgacle-page-number))))

(ert-deftest orgacle-test-jump-is-direct ()
  "Jumping does not visit the slides in between."
  (orgacle-test-with-fixture "slides.org"
    (orgacle--start-slides)
    (let ((visited 0))
      (let ((orgacle-page-hook (list (lambda () (setq visited (1+ visited))))))
        (orgacle-jump-to-page 3))
      (should (= 1 visited))
      (should (equal "Third slide" (org-entry-get nil "ITEM"))))))

(ert-deftest orgacle-test-start-slides-resets-the-page-number ()
  "A fresh `orgacle--start-slides' resets the page number along with
the index, not just the index by itself -- otherwise a second
presentation in the same session would open still showing the
previous presentation's page number."
  (orgacle-test-with-fixture "slides.org"
    (orgacle--start-slides)
    (orgacle-jump-to-page 3)
    (should (= 3 orgacle-page-number))
    (orgacle--start-slides)
    (should (= 0 (orgacle--session-index (orgacle--session-ensure))))
    (should (= 1 orgacle-page-number))))

(ert-deftest orgacle-test-nav-empty-deck-does-not-signal ()
  "A deck with no real slides -- here, only a title page -- does not
signal when navigated, and the page number reflects there being no
slide to show."
  (with-temp-buffer
    (let ((org-mode-hook nil)) (org-mode))
    (insert "* Title page\nNothing to see.\n")
    (orgacle--start-slides)
    (should (= 0 (length (orgacle--session-slides (orgacle--session-ensure)))))
    (should (= 0 orgacle-page-number))
    (should (progn (orgacle-top) t))
    (should (progn (orgacle-next-page) t))
    (should (progn (orgacle-previous-page) t))
    (should (progn (orgacle-jump-to-page 5) t))
    (should (= 0 orgacle-page-number))))

(ert-deftest orgacle-test-nav-commands-tolerate-a-fresh-sessions-nil-arithmetic ()
  "`orgacle-next-page', `orgacle-previous-page' and `orgacle-jump-to-page'
all survive a session whose index slot was never set by
`orgacle--start-slides'.  Reachable via `M-x orgacle-next-page' with no
presentation running -- `orgacle--session-ensure' auto-vivifies a fresh
session on demand -- or after `orgacle-quit' has set `orgacle--session'
back to nil.  Before the struct gave the index slot a default of 0,
`(1+ (orgacle--session-index ...))' and its `1-' counterpart were
`(1+ nil)' and `(1- nil)', both `wrong-type-argument' signals;
`orgacle-jump-to-page' was already immune because it computes from its
own argument, not the index slot, which is why it is included here
only to confirm it stays that way."
  (unwind-protect
      (progn
        (setq orgacle--session nil)
        (should (progn (orgacle-next-page) t))
        (setq orgacle--session nil)
        (should (progn (orgacle-previous-page) t))
        (setq orgacle--session nil)
        (should (progn (orgacle-jump-to-page 1) t)))
    (setq orgacle--session nil)))

(ert-deftest orgacle-test-refresh-rebuilds-the-slide-vector ()
  "Editing the outline during a presentation and refreshing keeps
navigation honest: no ORGACLE_HIDE heading is ever the current
heading afterwards, and the slide count matches the edited outline,
not a stale snapshot from before the edit."
  (orgacle-test-with-fixture "slides.org"
    (orgacle--start-slides)
    (orgacle-top)
    (orgacle-next-page)
    (should (equal "Second slide" (org-entry-get nil "ITEM")))
    ;; delete "First slide", including its subheading, entirely --
    ;; simulates an edit made during the presentation.  `widen' first:
    ;; `orgacle-next-page' narrowed to "Second slide", which is after
    ;; "First slide" in the buffer, so it is outside the accessible
    ;; region right now.
    (widen)
    (goto-char (point-min))
    (re-search-forward "^\\* First slide")
    (org-back-to-heading)
    (let ((beg (point)))
      (org-end-of-subtree t t)
      (delete-region beg (point)))
    ;; point is wherever the deletion left it; go back to the heading
    ;; the presenter was actually looking at before refreshing
    (goto-char (point-min))
    (re-search-forward "^\\* Second slide")
    (orgacle-refresh)
    (should (= 2 (length (orgacle--session-slides (orgacle--session-ensure)))))
    (should (= 1 orgacle-page-number))
    (should (equal "Second slide" (org-entry-get nil "ITEM")))
    ;; walk the whole, refreshed deck: no ORGACLE_HIDE heading is ever
    ;; the current heading
    (orgacle-top)
    (should (equal "Second slide" (org-entry-get nil "ITEM")))
    (should-not (org-entry-get nil "ORGACLE_HIDE"))
    (orgacle-next-page)
    (should (equal "Third slide" (org-entry-get nil "ITEM")))
    (should-not (org-entry-get nil "ORGACLE_HIDE"))))

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

(ert-deftest orgacle-test-quit-does-not-leave-a-stale-restriction ()
  "A restriction from a narrowed presentation does not leak into the next.

Presenting an ordinary, unnarrowed buffer afterwards, with a proper
`orgacle-quit' in between, must not leave that buffer narrowed to the
earlier restriction's bounds.  This already passed before the session
struct existed -- `orgacle-quit' has always reset the org-buffer and
org-restriction state together whenever it ran to completion -- but
stays as a regression guard now that the two are session slots
instead; see `orgacle-test-restriction-does-not-survive-a-skipped-quit'
for the related scenario that did not already pass."
  (orgacle-test-with-fixture "slides.org"
    (goto-char (point-min))
    (re-search-forward "^\\* First slide")
    (org-narrow-to-subtree)
    ;; simulate the narrowing bookkeeping `orgacle-run' does, without
    ;; creating a frame
    (setq orgacle--session (orgacle--session-create))
    (setf (orgacle--session-org-buffer orgacle--session) (current-buffer))
    (setf (orgacle--session-org-restriction orgacle--session)
          (list (point-min) (point-max)))
    (orgacle-quit))
  (orgacle-test-with-fixture "plain.org"
    ;; an ordinary, unnarrowed presentation of a different buffer
    (setq orgacle--session (orgacle--session-create))
    (setf (orgacle--session-org-buffer orgacle--session) (current-buffer))
    (orgacle-quit)
    (should-not (buffer-narrowed-p))))

(ert-deftest orgacle-test-restriction-does-not-survive-a-skipped-quit ()
  "A stale restriction does not survive a presentation that skips `orgacle-quit'.

Reproduces the sequence where a presentation's frame is killed with the
window manager instead of pressing q -- a re-entrancy scenario this
package already documents and partially guards against elsewhere, see
`orgacle--save-user-state' -- leaving a narrowed org-restriction slot
set when the next, unrelated `orgacle-run' begins.  Drives the real
`orgacle-run' for both presentations, with `orgacle--get-frame' stubbed
out (batch Emacs cannot create a real frame) and `orgacle-speaker-notes'
off (its notes frame uses `switch-to-buffer-other-frame', which signals
in batch), so this exercises `orgacle-run' replacing `orgacle--session'
with a fresh struct on every call -- the actual fix -- rather than a
hand-rolled stand-in for it: reverting that one line back to reusing an
existing session turns this test red again (verified; see the P3 task 4
report).  Before the session struct, this sequence signalled
`args-out-of-range' instead of merely narrowing to the wrong bounds,
because `orgacle--org-restriction' held raw buffer positions from an
entirely different, smaller buffer.

The first presentation needs a real file-visiting buffer, not the
anonymous `with-temp-buffer' `orgacle-test-with-fixture' uses: the
narrowed-region branch of `orgacle-run' calls `org-org-export-to-org',
which derives its output filename from `buffer-file-name' and prompts
interactively -- hanging batch Emacs -- when there is none."
  (let (source-file exported-file)
    (unwind-protect
        (cl-letf (((symbol-function 'orgacle--get-frame) (lambda () nil))
                  (orgacle-speaker-notes nil))
          (setq source-file (make-temp-file "orgacle-test-restriction" nil ".org"))
          (copy-file (expand-file-name "slides.org" orgacle-test-fixture-directory)
                     source-file t)
          (find-file source-file)
          (goto-char (point-min))
          (re-search-forward "^\\* First slide")
          (org-narrow-to-subtree)
          ;; a real presentation of a narrowed subtree, whose frame is
          ;; never quit -- simulating the window manager killing it
          ;; instead of `orgacle-quit' being pressed
          (orgacle-run)
          (setq exported-file (orgacle--session-org-file orgacle--session))
          (orgacle-test-with-fixture "plain.org"
            ;; a later, unrelated, ordinary presentation of a different,
            ;; unnarrowed buffer, with no `orgacle-quit' in between
            (orgacle-run)
            (orgacle-quit)
            (should-not (buffer-narrowed-p))))
      ;; both temp files and their buffers are cleaned up by
      ;; `orgacle-quit' in the ordinary case -- deliberately never
      ;; called for the first presentation here, so nothing else does
      ;; that cleanup; do it by hand instead
      (when exported-file
        (let ((buf (get-file-buffer exported-file)))
          (when buf (kill-buffer buf)))
        (when (file-exists-p exported-file)
          (delete-file exported-file)))
      (when source-file
        (let ((buf (find-buffer-visiting source-file)))
          (when buf (kill-buffer buf)))
        (when (file-exists-p source-file)
          (delete-file source-file))))))

(ert-deftest orgacle-test-run-displays-the-first-slide ()
  "`orgacle-run' narrows to slide 1 and shows page 1, not nothing.

`orgacle--start-slides' only builds the slide vector and resets the
index and page number to match; before this fix nothing narrowed the
buffer or ran the page hook, so `orgacle-run' left the presentation
looking blank with `orgacle-page-number' already at 1, and the first
`orgacle-next-page' computed (1+ 0) and jumped straight to slide 2 --
slide 1 was reachable only via `orgacle-top', `t' or `1'.  Batch Emacs
cannot create a real frame or an other-frame notes buffer, so
`orgacle--get-frame' is stubbed out and `orgacle-speaker-notes' is off,
matching `orgacle-test-quit-restores-tooltip-mode'."
  (orgacle-test-with-fixture "slides.org"
    (unwind-protect
        (cl-letf (((symbol-function 'orgacle--get-frame) (lambda () nil))
                  (orgacle-speaker-notes nil))
          (orgacle-run)
          (should (buffer-narrowed-p))
          (should (equal "First slide" (org-entry-get nil "ITEM")))
          (should-not (string-match-p "Second slide" (buffer-string)))
          (should (= 1 orgacle-page-number))
          (orgacle-next-page)
          (should (equal "Second slide" (org-entry-get nil "ITEM")))
          (should (= 2 orgacle-page-number)))
      (orgacle-quit))))

(ert-deftest orgacle-test-mode-enters ()
  "Entering `orgacle-mode' on a plain buffer completes without signaling.

A smoke test, not a characterization of everything the mode does: it
exists because nothing in the suite called `orgacle-mode' at all,
which let a byte-compile-only crash in its display-table handling
reach users unnoticed.  Batch mode has no frame of its own, so the
session's frame slot stays nil here; `set-face-attribute' with a nil
frame argument means the selected frame, which exists even in batch,
so the mode's frame-facing calls do not need a real one to complete.

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

;;; Frame lookup and restored global state

(ert-deftest orgacle-test-quit-deletes-the-sessions-frame ()
  "`orgacle-quit' deletes the frame recorded in the session.
Stubs `delete-frame' rather than really deleting the frame batch Emacs
runs in -- there is only one, and deleting the sole frame signals an
error (\"Attempt to delete the sole visible or iconified frame\")."
  (let ((session (orgacle--session-ensure))
        (deleted 'not-called))
    (unwind-protect
        (cl-letf (((symbol-function 'delete-frame)
                   (lambda (&optional frame _force) (setq deleted frame))))
          (setf (orgacle--session-frame session) (selected-frame))
          (orgacle-quit)
          (should (eq deleted (selected-frame))))
      (setq orgacle--session nil))))

(ert-deftest orgacle-test-quit-does-not-delete-an-unrelated-frame-titled-orgacle ()
  "A frame the user happens to have titled \"Orgacle\" is left alone.
`orgacle-quit' used to decide whether to delete a frame by comparing
`(frame-parameter nil \\='title)' to the literal string \"Orgacle\" --
any frame a user titled that way matched, regardless of whether it was
the presentation's own frame.  Batch Emacs has only the one, real, live
frame it starts with and cannot create a second one to stand in for
\"the user's other frame\", so this titles *that* frame \"Orgacle\" and
records no frame of its own in the session -- nil fails `frame-live-p'
exactly like a session that never reached `orgacle--get-frame', or one
whose frame was already killed by the window manager -- to prove the
decision now comes from the session, not the selected frame's title."
  (let ((session (orgacle--session-ensure))
        (deleted 'not-called)
        (orig-title (frame-parameter nil 'title)))
    (unwind-protect
        (cl-letf (((symbol-function 'delete-frame)
                   (lambda (&optional frame _force) (setq deleted frame))))
          (set-frame-parameter nil 'title "Orgacle")
          (setf (orgacle--session-frame session) nil)
          (orgacle-quit)
          (should (eq deleted 'not-called))
          (should (frame-live-p (selected-frame))))
      (set-frame-parameter nil 'title orig-title)
      (setq orgacle--session nil))))

(ert-deftest orgacle-test-get-frame-sets-fringe-only-on-its-own-frame ()
  "`orgacle--get-frame' scopes the `fringe' face to its own frame.
Calling `set-face-background' with no FRAME argument rewrites the
global default that every frame -- past and future -- inherits, not
just the presentation's own frame; that is the leak.  Batch Emacs
cannot create a second frame to show that some *other* frame is left
alone directly, so this instead seeds the session's frame slot with the
one real, live frame batch does have, which makes `orgacle--get-frame'
take its \"already have a live frame\" branch instead of calling
`make-frame' (which fails in batch), and checks the *global* default
via `(face-attribute \\='fringe :background t)' -- t as the FRAME
argument there means \"the value new frames would inherit\", which only
budges when `orgacle--get-frame' passes no FRAME of its own to
`set-face-background'; a properly scoped call leaves it unspecified."
  (let ((session (orgacle--session-ensure))
        (orig-x-pointer-shape (and (boundp 'x-pointer-shape) x-pointer-shape))
        (orig-x-sensitive (and (boundp 'x-sensitive-text-pointer-shape)
                                x-sensitive-text-pointer-shape)))
    (unwind-protect
        (progn
          (setf (orgacle--session-frame session) (selected-frame))
          (orgacle--get-frame)
          (should (eq 'unspecified (face-attribute 'fringe :background t))))
      (set-face-attribute 'fringe (selected-frame) :background 'unspecified)
      (setf (orgacle--session-frame session) nil)
      (when (boundp 'x-pointer-shape)
        (setq x-pointer-shape orig-x-pointer-shape)
        (setq x-sensitive-text-pointer-shape orig-x-sensitive)))))

(ert-deftest orgacle-test-get-frame-resyncs-mouse-visible-across-a-quit ()
  "`orgacle--get-frame' resets `orgacle-mouse-visible' when it forces the pointer visible.
Reproduces the session-boundary desync a code review caught: press `m'
in one presentation to hide the pointer, quit, start a second
presentation -- `orgacle--get-frame' always forces the actual pointer
visible for the new frame regardless of what the previous, already-quit
presentation left `orgacle-mouse-visible' at, but before this fix
nothing reset the variable to match.  With the variable still nil from
the earlier session and the pointer now genuinely visible, the first
`m' press in the new presentation would see `orgacle-mouse-visible' as
nil, decide \"already hidden, so show it\" -- and apply a shape the
pointer already has, a silent no-op; a second press would be needed
before anything visible happened.  Simulates the leftover nil directly,
the same way `orgacle-test-get-frame-sets-fringe-only-on-its-own-frame'
simulates \"already have a live frame\" by seeding the session's frame
slot with the one real frame batch Emacs has, taking `orgacle--get-frame's
\"already have a live frame\" branch instead of calling `make-frame'
\(which fails in batch\)."
  (let ((session (orgacle--session-ensure))
        (orgacle-mouse-visible nil)
        (orig-x-pointer-shape (and (boundp 'x-pointer-shape) x-pointer-shape))
        (orig-x-sensitive (and (boundp 'x-sensitive-text-pointer-shape)
                                x-sensitive-text-pointer-shape)))
    (unwind-protect
        (progn
          (setf (orgacle--session-frame session) (selected-frame))
          (orgacle--get-frame)
          (should orgacle-mouse-visible))
      (set-face-attribute 'fringe (selected-frame) :background 'unspecified)
      (setf (orgacle--session-frame session) nil)
      (when (boundp 'x-pointer-shape)
        (setq x-pointer-shape orig-x-pointer-shape)
        (setq x-sensitive-text-pointer-shape orig-x-sensitive)))))

(ert-deftest orgacle-test-toggle-mouse-flips-visibility-state-both-ways ()
  "`orgacle-toggle-mouse' actually alternates, instead of only ever hiding.
Before this fix, `orgacle-mouse-visible' was initialised to t and never
reassigned, so every call took the \"hide\" branch: the pointer only ever
went invisible, never back.  Asserts `orgacle-mouse-visible' itself,
not the X pointer variables it drives, because the latter exist only on
X11 builds and this test has to pass on any build; see the P3 task 7
brief for that call.  Two calls starting from t must land on nil then
back on t, proving both directions, not just that the value changed
once."
  (let ((orgacle-mouse-visible t))
    (orgacle-toggle-mouse)
    (should-not orgacle-mouse-visible)
    (orgacle-toggle-mouse)
    (should orgacle-mouse-visible)))

(ert-deftest orgacle-test-quit-restores-tooltip-mode ()
  "A presentation's `tooltip-mode' setting does not outlive it.
`orgacle-run' sets `tooltip-mode' to `orgacle-tooltip-mode' for the
duration of the presentation and used to never put it back, so a user
who had tooltips on lost them permanently after one presentation.
Batch Emacs cannot create a real frame, so `orgacle--get-frame' is
stubbed out, matching
`orgacle-test-restriction-does-not-survive-a-skipped-quit'."
  (orgacle-test-with-fixture "plain.org"
    (let ((original tooltip-mode))
      (unwind-protect
          (cl-letf (((symbol-function 'orgacle--get-frame) (lambda () nil))
                    (orgacle-speaker-notes nil)
                    (orgacle-tooltip-mode nil))
            (tooltip-mode 1)
            (orgacle-run)
            (should-not tooltip-mode)
            (orgacle-quit)
            (should tooltip-mode))
        (tooltip-mode (if original 1 -1))))))

(ert-deftest orgacle-test-quit-with-no-session-does-not-touch-tooltip-mode ()
  "Quitting with nothing running leaves `tooltip-mode' exactly as it was.
`orgacle--restore-user-state' guards its `tooltip-mode' restore on
`orgacle--saved-state' actually holding something, the same way it
already guards restoring the tracked variables and the
outline-ellipsis display-table slot.  Without that guard, calling
`orgacle-quit' with no presentation ever having started -- so
`orgacle--save-user-state' never ran and never captured the user's
real setting -- would unconditionally turn tooltips off, since
`orgacle-user-tooltip-mode' defaults to nil; this is the P2
\"quit is idempotent\" guarantee restated as \"no effect\", not merely
\"no signal\", for this one extra piece of state.

Both `orgacle-user-tooltip-mode' and `orgacle--saved-state' are
dynamically let-bound to their true \"nothing saved yet\" defaults
here, rather than trusted to already be that way: an earlier test in
the same batch run that legitimately saved and restored tooltip state
leaves `orgacle-user-tooltip-mode' holding its last real value, not
nil, since nothing ever resets it between tests -- and with the guard
missing, that leftover value can accidentally make the unconditional
restore land on the right answer anyway, hiding the exact regression
this test exists to catch.  Caught by running this test alone against
the unfixed code (RED) versus running the whole suite against it
(spuriously green, because of that leftover value) while developing
it; binding both variables here makes the test's result independent of
what ran before it."
  (let ((original tooltip-mode)
        (orgacle-user-tooltip-mode nil)
        (orgacle--saved-state nil))
    (unwind-protect
        (progn
          (tooltip-mode 1)
          (orgacle-quit)
          (orgacle-quit)
          (should tooltip-mode))
      (tooltip-mode (if original 1 -1)))))

(ert-deftest orgacle-test-quit-with-no-session-does-not-touch-display-table ()
  "Quitting with nothing running leaves the display table exactly as it was.
The same shape as
`orgacle-test-quit-with-no-session-does-not-touch-tooltip-mode', for
the other piece of state `orgacle--restore-user-state' puts back:
`orgacle-quit' used to overwrite the `selective-display' slot of
`standard-display-table' with `orgacle-outline-ellipsis' -- nil by
default -- whenever that table happened to already exist as a
char-table, regardless of whether `orgacle--save-user-state' had ever
actually captured it, clobbering a glyph the user or some other
package had set there.  `standard-display-table' commonly does already
exist by the time this runs -- Org itself, or many other packages, can
vivify it -- which is exactly what made this a live bug rather than a
theoretical one; setting it up explicitly here does not need any
unusual scaffolding to reproduce.

`orgacle-outline-ellipsis' and `orgacle--saved-state' are dynamically
let-bound to their true \"nothing saved yet\" defaults, for the same
test-order-independence reason as the tooltip test: an earlier test
that legitimately saved and restored the display table (for example
`orgacle-test-second-entry-preserves-outline-ellipsis') leaves
`orgacle-outline-ellipsis' holding its last real value, not nil, and
with the guard missing that leftover value could land on the right
answer by accident instead of proving anything."
  (unless (char-table-p standard-display-table)
    (setq standard-display-table (make-display-table)))
  (let ((original (display-table-slot standard-display-table 'selective-display))
        (orgacle-outline-ellipsis nil)
        (orgacle--saved-state nil))
    (unwind-protect
        (progn
          (set-display-table-slot standard-display-table 'selective-display
                                   "distinctive-user-glyph")
          (orgacle-quit)
          (orgacle-quit)
          (should (equal "distinctive-user-glyph"
                         (display-table-slot standard-display-table
                                             'selective-display))))
      (set-display-table-slot standard-display-table 'selective-display original))))

(ert-deftest orgacle-test-quit-with-no-session-does-not-touch-pointer-state ()
  "Quitting with nothing running leaves the pointer state exactly as it was.
The same shape as the tooltip-mode and display-table variants above,
for the third and last piece of state `orgacle--restore-user-state'
puts back -- the Task 5 review called this the final instance of the
same bug class those two fixes had already closed twice.  `orgacle-quit'
used to overwrite `x-pointer-shape' and `x-sensitive-text-pointer-shape'
with nil and `void-text-area-pointer' with \\='arrow -- discarding any
customization of it silently -- and then apply that to the mouse
pointer on the *selected* frame via `set-mouse-color', regardless of
whether `orgacle--save-user-state' had ever actually captured them.

Sets sentinel values with `setq' and restores the originals by hand in
the cleanup form, the same idiom
`orgacle-test-get-frame-sets-fringe-only-on-its-own-frame' uses for
these same three variables, rather than `let': all three are guarded
throughout the package by `(boundp \\='x-pointer-shape)', so wrapping the
whole test in that same guard, rather than `let'-binding variables that
might not exist, is what lets it run -- as a no-op -- on a build where
they are genuinely unbound too.

`orgacle-user-x-pointer-shape', `orgacle-user-x-sensitive-text-pointer-shape',
`orgacle-user-void-text-area-pointer' and `orgacle--saved-state' are
dynamically let-bound to their true \"nothing saved yet\" defaults, for
the same test-order-independence reason as the tooltip and
display-table variants: an earlier test that legitimately saved and
restored the pointer state would otherwise leave these holding a real
leftover value instead of the nil that lets a missing guard land on the
right answer by accident, hiding the exact regression this test exists
to catch."
  (when (boundp 'x-pointer-shape)
    (let ((orig-shape x-pointer-shape)
          (orig-sensitive x-sensitive-text-pointer-shape)
          (orig-void void-text-area-pointer)
          (orgacle-user-x-pointer-shape nil)
          (orgacle-user-x-sensitive-text-pointer-shape nil)
          (orgacle-user-void-text-area-pointer nil)
          (orgacle--saved-state nil))
      (unwind-protect
          (progn
            (setq x-pointer-shape 'orgacle-test-sentinel-shape
                  x-sensitive-text-pointer-shape 'orgacle-test-sentinel-sensitive
                  void-text-area-pointer 'orgacle-test-sentinel-void)
            (orgacle-quit)
            (orgacle-quit)
            (should (eq x-pointer-shape 'orgacle-test-sentinel-shape))
            (should (eq x-sensitive-text-pointer-shape 'orgacle-test-sentinel-sensitive))
            (should (eq void-text-area-pointer 'orgacle-test-sentinel-void)))
        (setq x-pointer-shape orig-shape
              x-sensitive-text-pointer-shape orig-sensitive
              void-text-area-pointer orig-void)))))

(provide 'orgacle-test)
;;; orgacle-test.el ends here
