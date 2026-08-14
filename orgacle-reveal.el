;;; orgacle-reveal.el --- Incremental reveal for Orgacle  -*- lexical-binding: t; -*-

;; This file is part of Orgacle.  See orgacle.el for the package header,
;; copyright and licence.

;;; Commentary:

;; Incremental reveal: a slide whose heading carries an ORGACLE_REVEAL
;; property starts with its targets -- top-level list items or direct
;; subheadings -- hidden, and reveals them one at a time going forward,
;; symmetrically hiding them again going back.  Replaces the old
;; ORGACLE_STEPWISE hack, which this file also now recognizes as an
;; alias for ORGACLE_REVEAL headings; see `orgacle--reveal-targets' for
;; both properties and the README's "Revealing a slide piece by piece"
;; section for the accordion-versus-cumulative behaviour change that
;; entails for an existing STEPWISE deck.

;;; Code:

(require 'org)
(require 'org-element)
(require 'orgacle-core)

(defvar orgacle--reveal-index 0
  "How many of the current slide's reveal targets are revealed.
Ranges from 0 (nothing revealed, the state every slide with reveal
targets starts in) to the length of `orgacle--reveal-overlays'
\(everything revealed\).  Target I is hidden while I is greater than or
equal to this; see `orgacle-reveal-next' and `orgacle-reveal-previous',
the only two functions that change it.  Reset to 0 for every slide by
`orgacle-reveal-reset', regardless of what it was left at on the slide
before -- see that function's docstring for why a slide is never
re-entered still partway revealed.")

(defvar orgacle--reveal-overlays nil
  "Vector of overlays for the current slide's reveal targets, in order.
One overlay per target `orgacle--reveal-targets' returned when this
vector was last built by `orgacle-reveal-reset', or nil for a slide
with no reveal targets at all.  Every overlay in the vector stays alive
for as long as the slide is displayed, whether its target is currently
hidden or not: `orgacle-reveal-next' and `orgacle-reveal-previous' only
flip an overlay's `invisible' property between `orgacle-hide' and nil,
never create or delete one -- which is what lets
`orgacle-reveal-previous' re-hide a target exactly where it was without
having to remember its buffer position separately.  Each overlay also
carries a non-nil `orgacle-reveal' property, so `orgacle-reveal-reset'
-- and, on `orgacle-quit', `orgacle-reveal-clean-overlays' -- can find
and delete a slide's whole set wholesale; kept in a list of its own
rather than joining `orgacle-overlays', the same way the fringe
indicators already keep `orgacle-fringe-overlays' separate; see
`orgacle-reveal-reset' for why.")

(defun orgacle--reveal-item-targets ()
  "Return (BEG . END) for each top-level list item in the narrowed buffer.
Called with the buffer narrowed to the current slide's subtree, by
`orgacle--reveal-targets', which see.  \"Top-level\" means a list item
whose own list is not itself nested inside another item -- a nested
sub-item is revealed together with the top-level item that contains
it, not as a separate target of its own."
  (let (targets)
    (org-element-map (org-element-parse-buffer) 'item
      (lambda (item)
        (let ((list-parent (org-element-property :parent item)))
          (unless (eq (org-element-type
                       (org-element-property :parent list-parent))
                      'item)
            (push (cons (org-element-property :begin item)
                        (org-element-property :end item))
                  targets)))))
    (nreverse targets)))

(defun orgacle--reveal-heading-targets ()
  "Return (BEG . END) for each direct subheading in the narrowed buffer.
Called with the buffer narrowed to the current slide's subtree and
point on its heading, by `orgacle--reveal-targets', which see.  Only
headings exactly one level below the slide's own count -- a
grandchild heading is revealed together with the direct subheading
that contains it, not as a separate target of its own, the same
one-level restriction `orgacle--reveal-item-targets' applies to nested
list items."
  (let ((level (org-current-level))
        targets)
    (org-map-entries
     (lambda ()
       (when (= (org-current-level) (1+ level))
         (push (cons (point) (save-excursion (org-end-of-subtree t t)))
               targets))))
    (nreverse targets)))

(defun orgacle--reveal-targets ()
  "Return the (BEG . END) ranges to reveal on the current slide, in order.
The current slide is read from the running session's slides and index
slots, via `orgacle--session-ensure', rather than from point -- so this
gives the same answer regardless of where point happens to be within
the slide when it is called, unlike a function that walked backward
from point to find the enclosing heading.

Reads the heading's ORGACLE_REVEAL property to decide what a target
is: \"items\" for `orgacle--reveal-item-targets', \"headings\" for
`orgacle--reveal-heading-targets'.  A heading with no ORGACLE_REVEAL
property but an ORGACLE_STEPWISE one is treated as ORGACLE_REVEAL
headings -- seeing ORGACLE_STEPWISE at all is enough, its value is
never inspected, the same way `orgacle-next-subheading' used to test
only for the property's presence.  An ORGACLE_REVEAL value that is
present but neither \"items\" nor \"headings\", and a slide with
neither property, both return nil: a slide with nothing configured
costs one or two cheap property lookups and nothing else, no matter
how many times this is called.

This is a pure read of the buffer as it currently stands: it never
creates, deletes, or otherwise touches an overlay.  `orgacle-reveal-reset'
is the only caller that turns the list this returns into hidden
overlays."
  (let* ((session (orgacle--session-ensure))
         (slides (orgacle--session-slides session))
         (index (orgacle--session-index session)))
    (when (> (length slides) 0)
      (let ((marker (aref slides index)))
        (when (marker-buffer marker)
          (with-current-buffer (marker-buffer marker)
            (save-excursion
              (save-restriction
                (widen)
                (goto-char marker)
                (let ((kind (or (org-entry-get nil "ORGACLE_REVEAL")
                                 (and (org-entry-get nil "ORGACLE_STEPWISE")
                                      "headings"))))
                  (when kind
                    (org-narrow-to-subtree)
                    (cond
                     ((string= kind "items") (orgacle--reveal-item-targets))
                     ((string= kind "headings") (orgacle--reveal-heading-targets))
                     (t nil))))))))))))

(defun orgacle-reveal-clean-overlays ()
  "Delete every overlay in `orgacle--reveal-overlays' and reset it to nil.
Safe to call with nothing to clean -- a slide with no reveal targets,
or a session with no presentation ever started -- since it is then a
no-op.  Called by `orgacle-reveal-reset' before it builds the new
slide's overlays, and by `orgacle-quit', the same way
`orgacle-clean-fringe-overlays' is; see `orgacle--reveal-overlays' for
why reveal keeps its own list instead of joining `orgacle-overlays'."
  (when orgacle--reveal-overlays
    (mapc #'delete-overlay orgacle--reveal-overlays))
  (setq orgacle--reveal-overlays nil))

(defun orgacle-reveal-reset ()
  "Delete the previous slide's reveal overlays and set up the new one.
A member of `orgacle-page-hook', so this runs every time a slide is
displayed, entering it from either direction or redisplaying it in
place.  Always calls `orgacle-reveal-clean-overlays' first,
unconditionally -- regardless of whether the slide now at point has
any reveal targets of its own -- which is what keeps a slide's reveal
overlays from surviving into the next slide: the leak class the phase
before this one spent three fix rounds on.  Then resets
`orgacle--reveal-index' to 0 and rebuilds `orgacle--reveal-overlays'
from `orgacle--reveal-targets', so a slide with reveal targets always
starts fully hidden, whether it is being entered for the first time or
returned to after being fully revealed earlier in the talk -- reveal
progress is per-visit, not remembered across a visit that left the
slide and came back.

Every overlay built here hides its target with the `orgacle-hide'
invisibility spec, the same spec `orgacle-mode' already registers via
`add-to-invisibility-spec' for every other kind of hidden content in a
presentation, and carries a non-nil `orgacle-reveal' property so this
function's own next call -- or `orgacle-reveal-clean-overlays' on
`orgacle-quit' -- can find the whole set again."
  (orgacle-reveal-clean-overlays)
  (setq orgacle--reveal-index 0)
  (let ((targets (orgacle--reveal-targets)))
    (setq orgacle--reveal-overlays
          (and targets
               (vconcat
                (mapcar (lambda (target)
                          (let ((ov (make-overlay (car target) (cdr target))))
                            (overlay-put ov 'invisible 'orgacle-hide)
                            (overlay-put ov 'orgacle-reveal t)
                            ov))
                        targets))))))

(defun orgacle--reveal-exhausted-p ()
  "Non-nil once every reveal target on the current slide is revealed.
Also non-nil, vacuously, for a slide with no reveal targets at all --
there being nothing left to reveal and there having never been
anything to reveal are the same state as far as `n' and `p' care,
via `orgacle-reveal-on-navigation': either way, navigation should not
wait on this slide."
  (or (null orgacle--reveal-overlays)
      (>= orgacle--reveal-index (length orgacle--reveal-overlays))))

(defun orgacle-reveal-next ()
  "Reveal the current slide's next hidden target, if any.
Returns non-nil if it moved, that is, if a target was actually
revealed; nil when `orgacle--reveal-exhausted-p' already held, in
which case nothing changes.  Flips the target's overlay's `invisible'
property to nil rather than deleting the overlay, so
`orgacle-reveal-previous' can hide the same target again later; see
`orgacle--reveal-overlays'.  Bound to \\='N\\=' regardless of
`orgacle-reveal-on-navigation', and also called by `orgacle-next-page'
-- see `orgacle-reveal-on-navigation' -- when that option is non-nil."
  (interactive)
  (when (and orgacle--reveal-overlays
             (< orgacle--reveal-index (length orgacle--reveal-overlays)))
    (overlay-put (aref orgacle--reveal-overlays orgacle--reveal-index)
                 'invisible nil)
    (setq orgacle--reveal-index (1+ orgacle--reveal-index))
    (redraw-display)
    t))

(defun orgacle-reveal-previous ()
  "Hide the current slide's last-revealed target again, if any.
Returns non-nil if it moved, that is, if a target was actually
re-hidden; nil when `orgacle--reveal-index' is already 0, in which case
nothing changes.  The exact symmetric inverse of `orgacle-reveal-next':
re-hides the same overlay that call revealed, rather than a fresh one,
so `orgacle-reveal-next' followed by `orgacle-reveal-previous' leaves
the slide in exactly the state it started in.  Bound to \\='P\\=' regardless
of `orgacle-reveal-on-navigation', and also called by
`orgacle-previous-page' -- see `orgacle-reveal-on-navigation' -- when
that option is non-nil."
  (interactive)
  (when (and orgacle--reveal-overlays (> orgacle--reveal-index 0))
    (setq orgacle--reveal-index (1- orgacle--reveal-index))
    (overlay-put (aref orgacle--reveal-overlays orgacle--reveal-index)
                 'invisible 'orgacle-hide)
    (redraw-display)
    t))

;; Joins `orgacle-page-hook' at load time, appended so it runs after
;; the built-in file/slide-in/indicators/notes sequence -- see the
;; `add-hook' calls and comments in orgacle-fontify.el and
;; orgacle-media.el for how that sequence's own order is kept.  Reveal
;; has no ordering dependency on any of the four, forward or backward,
;; so appending last is the lowest-risk placement absent a reason to
;; prefer another one.
(add-hook 'orgacle-page-hook #'orgacle-reveal-reset t)

(provide 'orgacle-reveal)
;;; orgacle-reveal.el ends here
