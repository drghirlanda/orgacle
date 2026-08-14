;;; orgacle-fontify.el --- Slide rendering for Orgacle  -*- lexical-binding: t; -*-

;; This file is part of Orgacle.  See orgacle.el for the package header,
;; copyright and licence.

;;; Commentary:

;; Slide rendering for Orgacle: fontifying the buffer for presentation,
;; the slide-in effect, and the font-scaling commands.

;;; Code:

(require 'orgacle-core)

(defun orgacle--slide-in-p ()
  "Return non-nil when the current slide should slide in.
`orgacle-slide-in' is the default; an ORGACLE_SLIDE_IN property of
\"no\", \"nil\" or \"off\" turns the animation off for one slide, and
any other value turns it on."
  (let ((property (org-entry-get nil "ORGACLE_SLIDE_IN")))
    (cond ((null property) orgacle-slide-in)
          ((member (downcase property) '("no" "nil" "off")) nil)
          (t t))))

(defun orgacle-slide-in-effect ()
  "Animate the current slide sliding in from below."
  (interactive)
  (when (orgacle--slide-in-p)
    (save-excursion
      (goto-char (point-min))
      (forward-line)
      ;; if there is a drawer, skip it
      (if (looking-at "[ \t]*:PROPERTIES:")
          (re-search-forward "^[ \t]*:END:[ \r\n]" nil t))
      (let ((ov (make-overlay (point) (point))))
        (dotimes (i orgacle-slide-in-lines)
          (if (eq i 1) (sit-for orgacle-slide-in-pause))
          (overlay-put ov 'after-string
                       (make-string (- orgacle-slide-in-lines i) ?\n))
          (sit-for (/ orgacle-slide-in-duration orgacle-slide-in-lines)))
        (delete-overlay ov)))))

(defconst orgacle-scalable-faces
  '(orgacle-title-face orgacle-heading-face orgacle-subheading-face
    orgacle-author-face orgacle-bullet-face)
  "Faces whose height `orgacle-increase-font' and its opposite change.")

(defconst orgacle-font-step 10
  "Amount `orgacle--scale-font' adds to or subtracts from an absolute height.
Applies to a face in `orgacle-scalable-faces' whose current :height is
an integer, i.e. an absolute size in 1/10 pt, such as
`orgacle-title-face'.")

(defconst orgacle-font-factor 1.1
  "Factor `orgacle--scale-font' multiplies or divides a relative height by.
Applies to a face in `orgacle-scalable-faces' whose current :height is
a float, i.e. a multiplier of the frame's default height, such as
`orgacle-author-face'.")

(defun orgacle--scale-font (grow)
  "Scale the height of every face in `orgacle-scalable-faces'.
With GROW non-nil the faces get larger, otherwise smaller.

`orgacle-scalable-faces' mixes faces whose :height is an absolute
integer with faces whose :height is a relative float multiplier.  An
absolute height is stepped by `orgacle-font-step'; a relative height
is scaled by `orgacle-font-factor'.  Either kind is clamped above
zero, so no sequence of calls can produce a non-positive height, which
`set-face-attribute' rejects."
  (dolist (face orgacle-scalable-faces)
    (let ((height (face-attribute face :height)))
      (set-face-attribute
       face nil :height
       (if (integerp height)
           (max 1 (+ height (if grow orgacle-font-step (- orgacle-font-step))))
         (max 0.1 (if grow (* height orgacle-font-factor)
                    (/ height orgacle-font-factor))))))))

(defun orgacle-increase-font ()
  "Make the presentation font one step larger."
  (interactive)
  (orgacle--scale-font t))

(defun orgacle-decrease-font ()
  "Make the presentation font one step smaller."
  (interactive)
  (orgacle--scale-font nil))

(defun orgacle-fontify ()
  "Overlay additional presentation faces to Org-mode."
  (save-excursion
    ;; hide all comments
    (goto-char (point-min))
    (while (re-search-forward
            "^[ \t]*#\\(\\+\\(author\\|title\\|date\\):\\)?.*\n"
            nil t)
      (cond
       ;; this avoids hiding title, author, or date
       ((and (match-string 2)
             (save-match-data
               (string-match (regexp-opt '("title" "author" "date"))
                             (match-string 2)))))
       ;; special handling of #+results
       ((and (match-string 2)
	     (save-match-data
	       (string-match org-babel-results-keyword (match-string 2))))
        ;; This pulls back the end of the hidden overlay by one to
        ;; avoid hiding image results of code blocks.  I'm not sure
        ;; why this is required, or why images start on the preceding
        ;; newline, but not knowing why doesn't make it less true.
        (push (make-overlay (match-beginning 0) (- (match-end 0) 1))
              orgacle-overlays)
        (overlay-put (car orgacle-overlays) 'invisible 'orgacle-hide))
       ((save-match-data
	  (string-match "^[ \t]*#\\+attr_org:.*?\n" (match-string 0)))
        (push (make-overlay (match-beginning 0) (- (match-end 0) 1))
              orgacle-overlays)
        (overlay-put (car orgacle-overlays) 'invisible 'orgacle-hide))
       ;; this hides all other comments
       (t (push (make-overlay (match-beginning 0) (match-end 0))
                orgacle-overlays)
          (overlay-put (car orgacle-overlays) 'invisible 'orgacle-hide))))
    ;; page title faces and heading/subheading faces
    (goto-char (point-min))
    (while (re-search-forward "^\\(*+\\)\\([ \t]+\\)\\(.*\\)$" nil t)
      ;; hide the first match, that is the stars
      (push (make-overlay (match-beginning 1) (or (match-end 2)
                                                 (match-end 1)))
           orgacle-overlays)
      (overlay-put (car orgacle-overlays) 'invisible 'orgacle-hide)
      ;; apply faces to heading and subheading
      (push (make-overlay (match-beginning 3) (match-end 3)) orgacle-overlays)
      (if (> (length (match-string 1)) 1)
          (overlay-put (car orgacle-overlays) 'face 'orgacle-subheading-face)
	  (overlay-put (car orgacle-overlays) 'face 'orgacle-heading-face)))
    ;; fancy bullet points, when the package is available
    (when (and orgacle-use-org-superstar (fboundp 'org-superstar-mode))
      (org-superstar-mode 1))
    ;; hide todos
    (when orgacle-hide-todos
      (goto-char (point-min))
      (while (re-search-forward org-todo-line-regexp nil t)
        (when (match-string 2)
          (push (make-overlay (match-beginning 2) (1+ (match-end 2)))
                orgacle-overlays)
          (overlay-put (car orgacle-overlays) 'invisible 'orgacle-hide))))
    ;; hide tags
    (when orgacle-hide-tags
      (goto-char (point-min))
      (while (re-search-forward
              "^\\*+.*?\\([ \t]+:[[:alnum:]_@#%:]+:\\)[ \r\n]"
              nil t)
        (push (make-overlay (match-beginning 1) (match-end 1)) orgacle-overlays)
        (overlay-put (car orgacle-overlays) 'invisible 'orgacle-hide)))
    ;; hide properties
    (when orgacle-hide-properties
      (goto-char (point-min))
      (while (re-search-forward org-drawer-regexp nil t)
        (let ((beg (match-beginning 0))
              (end (re-search-forward
                    "^[ \t]*:END:[ \r\n]"
                    (save-excursion (outline-next-heading) (point)) t)))
          (push (make-overlay beg end) orgacle-overlays)
          (overlay-put (car orgacle-overlays) 'invisible 'orgacle-hide))))
    (dolist (el '("title" "author" "date"))
      (goto-char (point-min))
      (when (re-search-forward (format "^\\(#\\+%s:[ \t]*\\)[ \t]*\\(.*\\)$" el) nil t)
        (push (make-overlay (match-beginning 1) (match-end 1)) orgacle-overlays)
        (overlay-put (car orgacle-overlays) 'invisible 'orgacle-hide)
        (push (make-overlay (match-beginning 2) (match-end 2)) orgacle-overlays)
        (overlay-put
         (car orgacle-overlays) 'face (intern (format "orgacle-%s-face" el)))))
    ;; inline images
    (orgacle--link-preview-clear)
    (orgacle--link-preview-refresh)))

;; `orgacle--build-notes-buffer' is defined in orgacle-notes.el, a
;; sibling module loaded after this one -- see the Makefile's EL list
;; and orgacle.el's `require' order.  `orgacle-refresh' below needs it
;; to keep a live notes buffer in step with a rebuilt slides slot, but
;; `require'-ing orgacle-notes here would load
;; it, and run its own `add-hook' call, before this file's own
;; `add-hook' call a little further down runs -- putting notes ahead
;; of slide-in and indicators in `orgacle-page-hook' instead of after
;; them; see orgacle-notes.el for that ordering.  `declare-function'
;; only silences the byte-compiler about a call to a function it
;; cannot see yet; orgacle.el's `require' order is what actually
;; guarantees the function exists by the time this is called for
;; real.  Same idiom as orgacle-nav.el's declaration of
;; `orgacle-toggle-hide-src-blocks'.
(declare-function orgacle--build-notes-buffer "orgacle-notes" ())

;; Same idiom, same reason, for orgacle-reveal.el's own rebuild-after-edit
;; function: `orgacle-refresh' below needs it so an edit that changes a
;; half-revealed slide's target count does not leave the reveal overlays
;; describing text that no longer matches what is actually there.
(declare-function orgacle-reveal-refresh "orgacle-reveal" ())

;; Same idiom again, this time for a function in orgacle-nav.el, loaded
;; *before* this file (see orgacle.el's `require' order) rather than
;; after -- so unlike the two declarations above, `require'-ing it here
;; directly would not even reorder anything page-hook-related.  Left as
;; a `declare-function' anyway, for the same reason `orgacle-nav.el'
;; itself declares `orgacle-toggle-hide-src-blocks' rather than
;; requiring orgacle-src: no feature module requires a sibling, full
;; stop, so each of these ten files still compiles standalone.
;; P4 Task 6 fix round 1 (Critical 1/2): `orgacle-refresh' below now
;; calls this directly, the same function ordinary navigation uses,
;; when and only when the slide it lands on has actually changed.
(declare-function orgacle-current-page "orgacle-nav" ())

(defun orgacle-refresh ()
  "Rebuild the slide vector, then delete overlays and re-fontify.
Bound to r, g, and to the key that exits `orgacle-edit-text', and
added to `org-babel-after-execute-hook' -- all points where the
presenter may just have edited the outline, which can move, add,
remove or hide a slide out from under the session's slides slot as it
stood when the presentation started (or since the last refresh).
Without rebuilding here, a stale vector entry can go on pointing at a
heading that no longer qualifies as a slide -- for example one just
given an ORGACLE_HIDE property, or one whose marker collapsed onto a
different heading because the slide it used to identify was deleted --
so later navigation would display it anyway, with no error to say so.
Re-derives the session's index slot from point via
`orgacle--slide-index-at-point' rather than leaving it at its
pre-refresh value, so the presenter stays on the slide they were
actually looking at even when the edit changed how many slides come
before it; `orgacle--sync-page-number' keeps `orgacle-page-number' in
step with that, including the empty-deck case.

Also rebuilds a live notes buffer via `orgacle--build-notes-buffer'.
Without that, the session's notes-markers slot would go on pointing at
the deck as it stood when the notes buffer was last built: inserting a
slide before the current one and refreshing would then leave the
re-derived index slot indexing the *old*, now-misaligned marker
vector, so the next navigation would show the wrong slide's notes --
silently, since the guard in `orgacle-position-notes' only catches an
index that runs past the end of the vector, not one that is merely
pointing at a different slide within it.

Also rebuilds the current slide's reveal overlays via
`orgacle-reveal-refresh', which clamps the reveal index to the
possibly-changed target count instead of simply resetting it, so an
edit that does not touch the target count leaves reveal progress
alone.  Its position relative to `orgacle-clean-overlays' below does
not actually matter for correctness, in either order: reveal overlays
deliberately do not live in the shared `orgacle-overlays' list that
call sweeps -- see `orgacle-reveal-clean-overlays's docstring for why
-- so that sweep can never see them regardless of
when `orgacle-reveal-refresh' runs relative to it, and
`orgacle-reveal-refresh' always deletes and rebuilds its own overlays
unconditionally, so it does not depend on anything this sweep does or
does not touch either.  It is placed after purely to read top to
bottom in the same order as the rest of this function: rebuild the
deck's own bookkeeping, clean up, then refresh the two things -- reveal
and fontification -- that redraw the current slide's actual content.

Transitions to the just-recomputed current slide, but only when it is
actually a *different* slide from the one the buffer was narrowed to
when this function was called -- P4 Task 6 Step 2 and its fix round 1
\(Critical 1 and Critical 2\).  Step 2's own first version re-narrowed
unconditionally, on every call: deleting the heading the presentation
is narrowed to -- for example by clearing it out entirely in `E'
edit-text mode and pressing the key that exits it, bound to this
function -- left the slides and index slots above correctly rebuilt,
but the buffer's actual restriction untouched, narrowed to a region
collapsed to zero width, showing nothing at all; reproduced directly
before that fix, and still fixed by this one.  But `orgacle-refresh'
is also on `org-babel-after-execute-hook', which fires after *every*
source-block execution, most of which do not change the current slide
at all -- and an unconditional `(goto-char ...)' there moved point
back to the slide's own heading on every single `x', breaking the
live-demo sequence `c' \(to a block\), `x' \(run it\), `c' \(to the
next block\): confirmed directly, reproducing the reviewer's own
two-block scenario, that the second `c' landed back on the *first*
block instead of the second, because `org-babel-next-src-block'
searches forward from wherever point now is.  Live, this also snaps
`window-start' back to the heading on every `x', destroying the
presenter's scroll position mid-demo -- the same `E'/`e' exit paths
that call this function share the defect for the same reason.

The fix: capture `(point-min)' -- the buffer's own current
restriction, whatever narrowed it there, before rebuilding anything --
and compare it, by position, to the just-recomputed current slide's
own marker.  Equal means the buffer is *already* narrowed to exactly
the slide this refresh lands on, so nothing needs to change: point is
left exactly where it was and nothing else in this branch runs, no
`widen', no `goto-char', no `org-narrow-to-subtree', no page hook --
what keeps `x' \(and an aborted or unchanged `e'/`E' edit\) cheap and
point-preserving, restoring the cost argument that motivated the
original Step 2 deferral, and now covering the `x' path too, not only
`r'/`g'.

A first version of this fix compared the session's index slot's own
marker, captured before rebuilding, to the new one by position instead
of comparing against `(point-min)' -- and passed every test written
for it, including the `c'/`x' sequence above, but not one written
directly against Critical 2's own appearance scenario: deleting a
slide whose *next* sibling immediately follows, with nothing in
between, collapses the deleted heading's own marker onto exactly the
position the next slide's marker also lands on after rebuilding --
confirmed directly, both markers ending up `eq' in position even
though the slide genuinely changed -- so that version wrongly
concluded \"unchanged\" and left the outgoing slide's appearance
applied.  `(point-min)' does not have *that* failure mode: the
currently narrowed heading's own start position does not move just
because content *inside* the narrowing changes, and does not coincide
with a different slide's position merely because that slide happens to
immediately follow the one that was deleted, the way a marker
collapsed by the deletion itself can.

But `(point-min)' alone has a failure mode of its own, fix round 2's
own Finding 1: on a deck with no preamble before its first heading --
no #+TITLE, no blank line, the buffer's very first character is that
heading's own leading star -- slide 1's own marker sits at position 1,
which coincides with `(point-min)' of a *fully widened* buffer too.
`x' does not always leave the restriction untouched the way this
docstring used to claim outright: a source block is ordinary Lisp
\(or whatever language\) and can call `(widen)' itself, nothing stops
it, and confirmed directly that when one does, `orgacle-refresh'
running afterward compared a genuinely widened `(point-min)' \(1\)
against slide 1's own marker \(also 1, on such a deck\), found them
equal, and concluded \"same slide, nothing to change\" -- leaving the
*entire* deck on screen, every slide's speaker notes included, instead
of re-narrowing to slide 1 alone.  `E' followed by `C-x n w' reaches
the same state without a special source block at all, since
`orgacle-edit-text' never narrows or widens on its own.  Fix round 2's
own fix added a second, independent trigger: `(not (buffer-narrowed-p))'
alongside the position comparison, either one enough on its own to
force a re-narrow.

That disjunct, in turn, has a false positive of its own, fix round 3's
own item 1: on a deck with exactly *one* slide and no preamble, that
slide's own subtree -- run through `org-narrow-to-subtree' -- covers
the entire buffer, so `buffer-narrowed-p' reads nil even when the
restriction is already exactly correct; there is nothing outside the
subtree to exclude.  `(not (buffer-narrowed-p))' then fires on *every*
refresh of such a deck, not only after a genuine widen.  Confirmed
directly, before fixing, with a slide carrying an ORGACLE_REVEAL
property advanced to step 2 and point moved away from the heading: a
plain, non-widening source block run via `x' reset the reveal index
to 0 and snapped point back to the heading, on a slide that had not
changed at all.

Replaced `buffer-narrowed-p' entirely with a direct comparison of both
ends of the restriction: `old-point-min'/`old-point-max', captured
before rebuilding, against `new-bounds', the just-recomputed slide's
own subtree bounds, computed the same way the real transition below
would arrive at them -- widen, go to the marker, `org-narrow-to-subtree'
-- but sandboxed in `save-excursion'/`save-restriction' so probing
those bounds does not itself move point or change the buffer's actual
restriction.  Equal bounds mean the view already shows exactly the
target slide's subtree, whether that got there through an ordinary
narrow or, as in the single-slide case above, through a widen that
happens to expose nothing else; either way nothing needs to change.
Unequal bounds catch a genuine transition, and, as a strict superset of
the old disjunct, still catch a widened multi-slide deck: there the
sandboxed bounds are the *narrower* target subtree while the old
restriction is the whole, wider buffer, so they compare unequal
regardless of where either one's `point-min' happens to fall.  The
sandboxed `org-narrow-to-subtree' call runs on every refresh once the
slides slot is non-empty, not only on an actual transition -- more work
than the old flag check, but still bounded by the target subtree's own
size, the same cost shape the rest of this function is built around,
and nowhere near the cost of the page hook it is here to avoid running
unnecessarily.

When the bounds differ, this calls `orgacle-current-page' -- the same
function ordinary navigation uses -- rather than repeating its work:
that function clears a stale aux-window slot as its own first act,
narrows to the new subtree, and runs `orgacle-page-hook' in full, so
per-slide appearance, incremental reveal and the notes buffer's
position are all torn down and rebuilt for the new slide the same way
entering it via `n'/`p' already would.  Reproduced directly, with the
`(point-min)'-based comparison in place, that deleting a slide with an
`ORGACLE_TEXT_SCALE' property and refreshing while its very next
sibling immediately follows no longer leaves that remapping in
`face-remapping-alist' once the view has moved to the sibling.
`widen' before `orgacle-current-page': that function's own
`org-narrow-to-subtree' call assumes an already-widened buffer \(see
`orgacle--goto-slide', the other caller, which widens first for the
same reason\), and narrowed to the *previous* slide's subtree, it would
do one of two wrong things to a *different* target slide instead:
signal `outline-before-first-heading' outright, unhandled by any
`condition-case' here, if the target starts before the old
restriction's own `(point-min)' -- Org's own comment on this reads
\"Preserve historical behavior throwing an error when current heading
starts before active narrowing\" -- or, if the target extends past the
old restriction's own `(point-max)', silently clamp the result short
of it instead of erroring -- Org's own comment on this one reads
\"Preserve historical behavior not extending the active narrowing\".
Corrected in this fix round from this docstring's own earlier, doubly
wrong claim that the function only ever *extends* a restriction and
that omitting `widen' here \"would silently do nothing\": neither
outcome is a silent no-op, and the first is not silent at all.

Guarded on a non-empty slides slot: an edit that leaves no slides at
all -- every heading deleted or ORGACLE_HIDE-tagged -- has no subtree
to transition to, the same guard `orgacle--goto-slide' applies to its
own work."
  (interactive)
  (let ((old-point-min (point-min))
        (old-point-max (point-max))
        (session (orgacle--session-ensure)))
    (setf (orgacle--session-slides session) (orgacle--build-slides))
    (setf (orgacle--session-index session) (orgacle--slide-index-at-point))
    (when (buffer-live-p (orgacle--session-notes-buffer session))
      (orgacle--build-notes-buffer))
    (let* ((slides (orgacle--session-slides session))
           (new-index (orgacle--session-index session))
           (new-marker (and (> (length slides) 0) (aref slides new-index)))
           (new-bounds
            (and new-marker
                 (save-excursion
                   (save-restriction
                     (widen)
                     (goto-char new-marker)
                     (org-narrow-to-subtree)
                     (cons (point-min) (point-max)))))))
      (when (and new-marker
                 (not (equal new-bounds (cons old-point-min old-point-max))))
        (widen)
        (goto-char new-marker)
        (orgacle-current-page))))
  (orgacle--sync-page-number)
  (orgacle-clean-overlays (point-min) (point-max))
  (orgacle-reveal-refresh)
  (orgacle-fontify))

;; Joins `orgacle-page-hook' at load time.  orgacle.el requires this
;; file before orgacle-media.el, so `orgacle-show-file-auto' is not
;; registered yet: this call has nothing to order itself against, and
;; it does not matter whether it prepends or appends.  See
;; orgacle-media.el for how the rest of the sequence is kept in the
;; order `orgacle-current-page' used to call these functions in.
(add-hook 'orgacle-page-hook #'orgacle-slide-in-effect)

(provide 'orgacle-fontify)
;;; orgacle-fontify.el ends here
