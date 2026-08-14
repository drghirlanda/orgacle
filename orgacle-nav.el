;;; orgacle-nav.el --- Slide navigation for Orgacle  -*- lexical-binding: t; -*-

;; This file is part of Orgacle.  See orgacle.el for the package header,
;; copyright and licence.

;;; Commentary:

;; Slide navigation for Orgacle: moving between pages and subheadings,
;; and presenting the current outline heading as a slide.

;;; Code:

(require 'org)
(require 'orgacle-core)

;; `orgacle-current-page' toggles source-block visibility directly,
;; via a function that lives in orgacle-src.el.  This file
;; deliberately does not require orgacle-src, to avoid a
;; sibling-module dependency; the declaration below only quiets the
;; byte-compiler.  Unlike the four subsystem calls Task 5 replaced
;; with `orgacle-page-hook', this one is not hook material: it has to
;; run inside the `org-fold-show-subtree' branch, before the hook's
;; members see the slide, not after.
;;
;; P3 Task 2 re-examined this rather than carrying it forward
;; unexamined: the mutual recursion between `orgacle-current-page' and
;; the page-movement commands is gone now that navigation is index
;; arithmetic over the session's slides slot, but that recursion was
;; never what motivated this declaration.  The sequencing constraint above
;; -- src-block visibility has to be set inside the same conditional
;; that decides whether this heading is a real slide, strictly before
;; `orgacle--run-page-hook' -- is untouched by the rewrite, so the
;; declaration stays for the same reason P2 added it.
(declare-function orgacle-toggle-hide-src-blocks "orgacle-src" (&optional arg))

;; `orgacle-next-page' and `orgacle-previous-page' consult reveal state
;; before moving to another slide, when `orgacle-reveal-on-navigation'
;; -- a plain variable, needing no declaration -- is non-nil.  Declared
;; rather than required for the same reason `orgacle-toggle-hide-src-blocks'
;; is above: no feature module may require a sibling, and orgacle.el's
;; own require order guarantees both are defined before either is ever
;; actually called.
(declare-function orgacle-reveal-next "orgacle-reveal" ())
(declare-function orgacle-reveal-previous "orgacle-reveal" ())
(declare-function orgacle-reveal-clean-overlays "orgacle-reveal" ())

(defun orgacle--start-slides ()
  "Build the session's slides slot and reset navigation to the first slide.
Sets the slides slot from `orgacle--build-slides', the index slot to 0,
and `orgacle-page-number' to match via `orgacle--sync-page-number' --
the index alone is not enough, or a second presentation started in the
same Emacs session would open still showing the previous
presentation's page number until the first navigation command ran.
Called once per presentation -- by `orgacle-run', and directly by
tests that exercise navigation without starting a full presentation --
after which `orgacle-top', `orgacle-next-page', `orgacle-previous-page'
and `orgacle-jump-to-page' are index arithmetic over the vector it
builds.

Also clears any reveal overlays and resets the reveal index left over
from whatever was on display before.  The session struct's own
reveal-overlays and reveal-index slots are already guaranteed fresh
for a *brand-new* session -- see their docstring in orgacle-core.el --
but `orgacle--session-ensure' reuses an *existing* session when one is
already current, which is exactly what happens here when this function
runs a second time without an intervening `orgacle-quit': directly,
from a second `orgacle-run'; and in the test suite, from one fixture's
buffer to the next, since `orgacle-test-with-fixture' does not call
`orgacle-quit' between tests.  Without this explicit reset, a reused
session would carry the previous buffer's reveal overlays and index
into `orgacle--start-slides''s caller here, exactly as the slides and
index slots just above would if this function did not also reset
those by hand."
  (let ((session (orgacle--session-ensure)))
    (setf (orgacle--session-slides session) (orgacle--build-slides))
    (setf (orgacle--session-index session) 0))
  (orgacle--sync-page-number)
  (orgacle-reveal-clean-overlays)
  (let ((session (orgacle--session-ensure)))
    (setf (orgacle--session-reveal-index session) 0
          (orgacle--session-reveal-enter-revealed session) nil)))

(defun orgacle--goto-slide (index)
  "Move to slide INDEX of the session's slides slot and present it.
INDEX is clamped to the deck here -- below 0 goes to the first slide,
at or past the last valid index goes to the last slide -- which is why
`orgacle-next-page', `orgacle-previous-page' and `orgacle-jump-to-page'
below can pass plain arithmetic and leave clamping to this, their one
shared entry point, rather than each repeating it.  Sets the session's
index slot to the clamped value and `orgacle-page-number' to match via
`orgacle--sync-page-number', re-selects the presentation window (see
below), widens the slide's own buffer, moves point to the slide's
marker, and calls `orgacle-current-page' exactly once.  That single
call is what makes jumping any number of slides cost one redisplay
instead of one per slide skipped over.  Does nothing when the slides
slot is empty, which an Org buffer with no headings at all produces;
there is then no slide to move to.

Selects the session's presentation-window slot when it is still live,
which is what makes `orgacle-page-hook''s own contract -- \"a slide
has been displayed\" before members run, not merely narrowed in the
right buffer somewhere off-screen -- actually true regardless of what
was selected when this was called, rather than only when the caller
happened to leave the right window selected.  It was not, for real, in
the default configuration: `orgacle-run' calls `orgacle-make-notes-buffer',
whose last act is `switch-to-buffer-other-frame' to the notes buffer
in its own frame, immediately before calling `orgacle-top' with no
window selection of its own in between -- so the first
`orgacle-current-page' of every presentation with speaker notes on at
their default used to run with the *notes* window selected, not the
presentation window.

Fix round 2 (Critical 2) addressed the buffer half of this with plain
`set-buffer', which fixed three of the four affected page-hook members
-- `orgacle--apply-appearance', `orgacle-slide-in-effect' and
`orgacle-show-indicators-maybe' only ever read `org-entry-get'/point in
the current buffer, so making that buffer correct was enough for them
-- but `set-buffer' changes no display, and the fourth,
`orgacle-show-file-auto', also calls `delete-other-windows' and
`split-window-right'/`split-window-below' on the *selected* window via
`orgacle-show-file'.  With only the buffer fixed, those calls still
landed in the notes frame: confirmed live, under Xvfb, with speaker
notes at their default and a slide carrying ORGACLE_SHOW_AUTO -- the
auto-shown file split the *notes* frame in half instead of the
presentation frame, worse for a live talk than fix round 2's own
\"nothing appears anywhere\" starting point.  Selecting
presentation-window here, before the page hook runs, fixes this
properly: selecting a window always selects its frame and buffer too,
so `orgacle-show-file''s window-splitting calls now land back where
every other slide already puts them.  Falls back to `set-buffer' on
the slide's own marker buffer when presentation-window is not live --
nil, because nothing has called `orgacle-run' yet (every test in this
suite that exercises navigation directly, without a full run), or a
window the presenter closed by hand -- so a slide can still narrow and
run its hook in that fallback, the same guarantee fix round 2
established, but not every member runs *correctly* there: fix round 4
confirmed live that `orgacle-show-file-auto', on a slide carrying
ORGACLE_SHOW_AUTO, signals `Wrong type argument: window-live-p' in
this exact fallback, because `orgacle-show-file' itself unconditionally
calls `select-window' on the session's presentation-window at its own
end, with no live-window guard of its own.  `orgacle--run-page-hook'
catches and logs it, same as any other failing member, so this stays
non-fatal to the presentation, but \"narrow and run the hook\" is not
the same claim as \"every member behaves correctly\" and this
docstring should not have implied the latter.  `orgacle-position-notes'
and `orgacle-reveal-reset', the other two page-hook members, were
never affected either way -- the former always explicitly selects the
notes
buffer's own window via `with-selected-window' regardless of what is
selected, and the latter locates its slide from the session's own
slides/index slots rather than from point or the selected window at
all; see the tests named `...-narrows-the-slides-own-buffer-...' and
`...-reselects-the-presentation-window' in test/orgacle-test.el for
how both halves of this were reproduced and confirmed fixed."
  (let* ((session (orgacle--session-ensure))
         (slides (orgacle--session-slides session)))
    (when (> (length slides) 0)
      (setf (orgacle--session-index session)
            (max 0 (min (1- (length slides)) index)))
      (orgacle--sync-page-number)
      (let ((window (orgacle--session-presentation-window session))
            (buffer (marker-buffer (aref slides (orgacle--session-index session)))))
        (if (window-live-p window)
            (progn
              (select-window window)
              ;; belt-and-braces: in every real presentation
              ;; `presentation-window' already shows this exact
              ;; buffer, since `orgacle-run' records it right after
              ;; entering `orgacle-mode' in that buffer and nothing
              ;; ever redisplays a different one into it -- confirmed
              ;; live, under Xvfb.  Corrected explicitly anyway,
              ;; rather than trusting that invariant unconditionally:
              ;; it does not hold for a live window whose buffer was
              ;; never actually the presented one to begin with, which
              ;; the batch test suite's own `orgacle--get-frame'-stubbed
              ;; tests can produce (a real window that happens to be
              ;; showing something else when `orgacle-run' captured
              ;; it) -- caught directly, fix round 3, by this file's
              ;; own window-reselection test breaking three unrelated
              ;; `orgacle-run'-based tests until this line was added.
              (when (and (buffer-live-p buffer) (not (eq (window-buffer window) buffer)))
                ;; `set-window-buffer' alone changes what the window
                ;; displays but not `current-buffer' for the selected
                ;; window -- confirmed directly; `select-window'
                ;; already made WINDOW's *old* buffer current above,
                ;; so both calls are needed, in this order, to leave
                ;; the window showing BUFFER and BUFFER itself current
                (set-window-buffer window buffer)
                (set-buffer buffer)))
          (when (buffer-live-p buffer)
            (set-buffer buffer))))
      (widen)
      (goto-char (aref slides (orgacle--session-index session)))
      (orgacle-current-page))))

(defun orgacle-jump-to-page (num)
  "Jump directly to page NUM of the presentation.
NUM is clamped to the deck by `orgacle--goto-slide': below 1 goes to
the first slide, above the last slide goes to the last one."
  (interactive "npage number: ")
  (orgacle--goto-slide (1- num)))

(defun orgacle-current-page ()
  "Present the current outline heading as a slide."
  (interactive)
  (let ((session (orgacle--session-ensure)))
    (when (orgacle--session-aux-window session)
      (delete-window (orgacle--session-aux-window session))
      (setf (orgacle--session-aux-window session) nil)))
  (if (org-current-level)
      (progn
	(org-narrow-to-subtree)
	(outline-show-all)
	(outline-hide-body)
	(when (>= (org-reduced-level (org-current-level))
		  orgacle-frame-level)
	  (org-fold-show-subtree)
	  (org-cycle-set-visibility-according-to-property) ;; folds children
	  (let ((orgacle-src-block-toggle-state
		 (if orgacle-src-blocks-visible :show :hide)))
	    (orgacle-toggle-hide-src-blocks)))
	(orgacle--run-page-hook))
    ;; before first headline -- fold up subtrees as TOC
    (org-cycle '(4)))
  ; this is sometimes useful:
  (redraw-display))

(defun orgacle-top ()
  "Present the first slide."
  (interactive)
  ;; rewind notes buffer if present
  (let ((notes-buffer (orgacle--session-notes-buffer (orgacle--session-ensure))))
    (if notes-buffer
        (with-current-buffer notes-buffer
          (goto-char (point-min)))))
  (orgacle--goto-slide 0))

(defun orgacle-next-page ()
  "Advance an in-progress reveal, or advance to the next slide.
With `orgacle-reveal-on-navigation' non-nil (the default) and the
current slide's reveal not yet exhausted, calls `orgacle-reveal-next'
and stops there -- the slide does not change.  Otherwise moves to the
next slide exactly as before this option existed.  Past the last
slide, nothing moves and the last slide stays on display;
`orgacle--goto-slide' is what clamps that."
  (interactive)
  (unless (and orgacle-reveal-on-navigation (orgacle-reveal-next))
    (orgacle--goto-slide (1+ (orgacle--session-index (orgacle--session-ensure))))))

(defun orgacle-previous-page ()
  "Step an in-progress reveal back, or present the previous slide.
With `orgacle-reveal-on-navigation' non-nil (the default) and the
current slide's reveal index above 0, calls `orgacle-reveal-previous'
and stops there -- the slide does not change.  Otherwise moves to the
previous slide exactly as before this option existed, landing on it
fully revealed rather than fully hidden, matching Beamer and
reveal.js: stepping backward across a slide boundary shows that
slide's last step, not its bare heading, so returning to a slide does
not cost its target count in `n' presses just to see what was already
shown before.  Signalled to `orgacle-reveal-reset' -- which actually
builds the destination slide's overlays -- via the session's
reveal-enter-revealed slot, set here only when a slide change is
actually about to happen; at the first slide already, where
`orgacle--goto-slide' clamps back to the same slide and still re-runs
the page hook, leaving the flag unset here is what keeps that
redundant redisplay from re-revealing a slide already at reveal index
0 that the presenter never actually left.  Before the first slide,
nothing moves and the first slide stays on display; `orgacle--goto-slide'
is what clamps that."
  (interactive)
  (unless (and orgacle-reveal-on-navigation (orgacle-reveal-previous))
    (let ((session (orgacle--session-ensure)))
      (when (> (orgacle--session-index session) 0)
        (setf (orgacle--session-reveal-enter-revealed session) t))
      (orgacle--goto-slide (1- (orgacle--session-index session))))))

(defun orgacle-next-subheading ()
  "Advance to next subheading, unhiding it if hidden."
  (interactive)
  (when (and (org-entry-get nil "ORGACLE_STEPWISE")
	   (> (org-current-level) 1))
      (outline-hide-subtree))
  (org-next-visible-heading 1)
  (org-fold-show-subtree))

(defun orgacle-previous-subheading ()
  "Go back to previous subheading, possibly hiding the current one."
  (interactive)
  (when (> (org-current-level) 1)
    (outline-hide-subtree))
  (org-next-visible-heading -1) ; -1 means previous
  (if (> (org-current-level) 1) ; show if we found a subheading
      (org-fold-show-subtree)))

(provide 'orgacle-nav)
;;; orgacle-nav.el ends here
