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
;; section for what actually changes for an existing STEPWISE deck.

;;; Code:

(require 'org)
(require 'org-element)
(require 'orgacle-core)

(defun orgacle--reveal-current-marker ()
  "Return the current slide's marker, or nil when there is no deck yet.
Reads the running session's slides and index slots, via
`orgacle--session-ensure', rather than point -- so this gives the same
answer regardless of where point happens to be, unlike a function that
walked backward from point to find the enclosing heading.  The single
place `orgacle--reveal-targets', `orgacle-reveal-reset' and
`orgacle-reveal-refresh' all locate the current slide from, so the
three of them can never disagree about which slide that is."
  (let* ((session (orgacle--session-ensure))
         (slides (orgacle--session-slides session)))
    (and (> (length slides) 0) (aref slides (orgacle--session-index session)))))

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
The current slide comes from `orgacle--reveal-current-marker', not
point, for the reason given there.

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
and `orgacle-reveal-refresh' are the only callers that turn the list
this returns into hidden overlays."
  (let ((marker (orgacle--reveal-current-marker)))
    (when (and marker (marker-buffer marker))
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
                 (t nil))))))))))

(defun orgacle--reveal-build-overlays (targets buffer)
  "Return a vector of fresh, hidden reveal overlays for TARGETS in BUFFER.
One overlay per (BEG . END) cons in TARGETS, in order, each created
explicitly in BUFFER via `make-overlay's own BUFFER argument rather
than relying on whatever buffer happens to be current at the call
site -- `orgacle--reveal-targets' computes BEG and END inside
`with-current-buffer' on the slide's own marker buffer, which is not
guaranteed to still be current by the time this runs, only reliably
true while `orgacle--run-page-hook's `save-current-buffer' wrapper is
on the stack.  Each overlay starts hidden, with `invisible' set to
`orgacle-hide' -- the same spec `orgacle-mode' already registers via
`add-to-invisibility-spec' for every other kind of hidden content in a
presentation -- and carries a non-nil `orgacle-reveal' property, so the
whole set can be found and deleted wholesale by
`orgacle-reveal-clean-overlays'.  A caller that wants some of them to
start visible instead, such as `orgacle-reveal-reset' landing on a
slide entered from behind, flips `invisible' back to nil afterward."
  (vconcat
   (mapcar (lambda (target)
             (let ((ov (make-overlay (car target) (cdr target) buffer)))
               (overlay-put ov 'invisible 'orgacle-hide)
               (overlay-put ov 'orgacle-reveal t)
               ov))
           targets)))

(defun orgacle-reveal-clean-overlays ()
  "Delete every overlay in the session's reveal-overlays slot; reset it to nil.
Safe to call with nothing to clean -- a slide with no reveal targets,
or a session with no presentation ever started -- since it is then a
no-op.  Called by `orgacle-reveal-reset' and `orgacle-reveal-refresh'
before each builds a fresh set, and by `orgacle-quit', the same way
`orgacle-clean-fringe-overlays' is; see the session struct's
reveal-overlays slot docstring in orgacle-core.el for why reveal keeps
its own list instead of joining `orgacle-overlays'."
  (let* ((session (orgacle--session-ensure))
         (overlays (orgacle--session-reveal-overlays session)))
    (when overlays (mapc #'delete-overlay overlays))
    (setf (orgacle--session-reveal-overlays session) nil)))

(defun orgacle-reveal-reset ()
  "Delete the previous slide's reveal overlays and set up the new one.
A member of `orgacle-page-hook', so this runs every time a slide is
displayed, entering it from either direction or redisplaying it in
place.  Always calls `orgacle-reveal-clean-overlays' first,
unconditionally -- regardless of whether the slide now at point has
any reveal targets of its own -- which is what keeps a slide's reveal
overlays from surviving into the next slide: the leak class the phase
before this one spent three fix rounds on.

Ordinarily rebuilds the new slide starting fully hidden, at reveal
index 0.  The one exception: when the session's reveal-enter-revealed
slot is non-nil -- set by `orgacle-previous-page' immediately before
it steps back onto a new slide, so the audience lands on that slide's
last step rather than its bare heading, matching how Beamer and
reveal.js both treat stepping backward across a slide boundary -- this
instead starts the slide fully revealed, at the highest index.  That
flag is one-shot: read once here and always cleared immediately
afterward, so redisplaying the same slide again (a refresh, or simply
returning to it a second time without stepping backward into it) does
not keep re-triggering the fully-revealed start.

Every overlay is built by `orgacle--reveal-build-overlays', which see
for why it takes the target buffer explicitly rather than trusting
`current-buffer'."
  (orgacle-reveal-clean-overlays)
  (let* ((session (orgacle--session-ensure))
         (enter-revealed (orgacle--session-reveal-enter-revealed session))
         (marker (orgacle--reveal-current-marker))
         (targets (orgacle--reveal-targets))
         (overlays (and targets marker
                        (orgacle--reveal-build-overlays targets (marker-buffer marker)))))
    (setf (orgacle--session-reveal-enter-revealed session) nil)
    (setf (orgacle--session-reveal-overlays session) overlays)
    (if (and enter-revealed overlays)
        (progn
          (mapc (lambda (ov) (overlay-put ov 'invisible nil)) overlays)
          (setf (orgacle--session-reveal-index session) (length overlays)))
      (setf (orgacle--session-reveal-index session) 0))))

(defun orgacle-reveal-refresh ()
  "Rebuild the current slide's reveal overlays after a buffer edit.
Called by `orgacle-refresh', unlike `orgacle-reveal-reset', which the
page hook calls: an edit -- most directly `E' followed by exiting edit
mode, which calls `orgacle-refresh' -- can change the current slide's
text without changing which slide is current, so the reveal targets'
buffer positions, and even how many targets there are, may no longer
match the overlays built the last time the slide was entered or
refreshed.

Deletes the stale overlays and rebuilds fresh ones from
`orgacle--reveal-targets' recomputed against the edited buffer, but --
unlike `orgacle-reveal-reset', which always starts a slide at 0 or at
the top -- preserves how many were revealed, clamped to the new target
count: reveal progress survives a refresh when the count is unchanged,
and adapts, rather than desyncing, when editing has added or removed
targets.  `orgacle-refresh's own `orgacle-clean-overlays' sweeps the
shared `orgacle-overlays' list on every call, which is exactly why
reveal overlays living in that list instead of their own would be
silently wiped, with nothing here to rebuild them, on every refresh."
  (let* ((session (orgacle--session-ensure))
         (old-index (orgacle--session-reveal-index session)))
    (orgacle-reveal-clean-overlays)
    (let* ((marker (orgacle--reveal-current-marker))
           (targets (orgacle--reveal-targets))
           (overlays (and targets marker
                          (orgacle--reveal-build-overlays targets (marker-buffer marker))))
           (new-index (min old-index (length overlays))))
      (setf (orgacle--session-reveal-overlays session) overlays)
      (setf (orgacle--session-reveal-index session) new-index)
      (dotimes (i (length overlays))
        (overlay-put (aref overlays i)
                     'invisible (if (< i new-index) nil 'orgacle-hide))))))

(defun orgacle--reveal-exhausted-p ()
  "Non-nil once every reveal target on the current slide is revealed.
Also non-nil, vacuously, for a slide with no reveal targets at all --
there being nothing left to reveal and there having never been
anything to reveal are the same state as far as `n' and `p' care,
via `orgacle-reveal-on-navigation': either way, navigation should not
wait on this slide."
  (let* ((session (orgacle--session-ensure))
         (overlays (orgacle--session-reveal-overlays session)))
    (or (null overlays)
        (>= (orgacle--session-reveal-index session) (length overlays)))))

(defun orgacle-reveal-next ()
  "Reveal the current slide's next hidden target, if any.
Returns non-nil if it moved, that is, if a target was actually
revealed; nil when `orgacle--reveal-exhausted-p' already held, in
which case nothing changes.  Flips the target's overlay's `invisible'
property to nil rather than deleting the overlay, so
`orgacle-reveal-previous' can hide the same target again later; see
`orgacle--reveal-build-overlays'.  Bound to \\='N\\=' regardless of
`orgacle-reveal-on-navigation', and also called by `orgacle-next-page'
-- see `orgacle-reveal-on-navigation' -- when that option is non-nil."
  (interactive)
  (let* ((session (orgacle--session-ensure))
         (overlays (orgacle--session-reveal-overlays session))
         (index (orgacle--session-reveal-index session)))
    (when (and overlays (< index (length overlays)))
      (overlay-put (aref overlays index) 'invisible nil)
      (setf (orgacle--session-reveal-index session) (1+ index))
      t)))

(defun orgacle-reveal-previous ()
  "Hide the current slide's last-revealed target again, if any.
Returns non-nil if it moved, that is, if a target was actually
re-hidden; nil when the reveal index is already 0, in which case
nothing changes.  The exact symmetric inverse of `orgacle-reveal-next':
re-hides the same overlay that call revealed, rather than a fresh one,
so `orgacle-reveal-next' followed by `orgacle-reveal-previous' leaves
the slide in exactly the state it started in.  Bound to \\='P\\=' regardless
of `orgacle-reveal-on-navigation', and also called by
`orgacle-previous-page' -- see `orgacle-reveal-on-navigation' -- when
that option is non-nil."
  (interactive)
  (let* ((session (orgacle--session-ensure))
         (overlays (orgacle--session-reveal-overlays session))
         (index (orgacle--session-reveal-index session)))
    (when (and overlays (> index 0))
      (overlay-put (aref overlays (1- index)) 'invisible 'orgacle-hide)
      (setf (orgacle--session-reveal-index session) (1- index))
      t)))

;; Joins `orgacle-page-hook' at load time with no APPEND, i.e.
;; prepended -- and this ordering is a real correctness dependency,
;; not cosmetic: `orgacle-slide-in-effect' (registered by
;; orgacle-fontify.el) calls `sit-for', which forces a real redisplay
;; mid-animation.  This file's first attempt registered reveal with
;; APPEND-t, intending "runs last"; the actual effect, given
;; orgacle-reveal.el's require position, was reveal landing *after*
;; slide-in, so a slide-in deck with reveal targets showed every
;; target for about a second (the slide-in pause plus animation) and
;; only then hid them -- visible to the audience.  Reveal must run
;; before slide-in, so its overlays already exist when the animation's
;; own `sit-for' forces that first redisplay.
;;
;; A bare (prepend) `add-hook' call is what achieves that here without
;; reintroducing the same require-order coupling under a new name: it
;; only needs this call to run after orgacle-fontify.el's and
;; orgacle-media.el's own prepending calls (`orgacle-slide-in-effect'
;; and `orgacle-show-file-auto', the only other two members that also
;; prepend) -- not after all four contributors the way the APPEND
;; version needed, since `orgacle-show-indicators-maybe' and
;; `orgacle-position-notes' both append and so never contest the front
;; of the list regardless of when they are registered relative to this
;; call.  orgacle-reveal.el is required after both fontify and media
;; (last of all five, in fact; see orgacle.el), which is more than
;; enough, and unlike the strict "after all four" the APPEND version
;; needed, moving orgacle-notes.el's own require earlier or later could
;; never disturb this.
(add-hook 'orgacle-page-hook #'orgacle-reveal-reset)

(provide 'orgacle-reveal)
;;; orgacle-reveal.el ends here
