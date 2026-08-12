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
;; arithmetic over `orgacle--slides', but that recursion was never
;; what motivated this declaration.  The sequencing constraint above
;; -- src-block visibility has to be set inside the same conditional
;; that decides whether this heading is a real slide, strictly before
;; `orgacle--run-page-hook' -- is untouched by the rewrite, so the
;; declaration stays for the same reason P2 added it.
(declare-function orgacle-toggle-hide-src-blocks "orgacle-src" (&optional arg))

(defun orgacle-goto-top-level ()
  "Go to the current top level heading containing point."
  (interactive)
  (unless (org-at-heading-p) (outline-previous-heading))
  (let ((level (ignore-errors (org-reduced-level (org-current-level)))))
    (when (and level (> level orgacle-frame-level))
      (org-up-heading-all (- level orgacle-frame-level)))))

(defun orgacle--start-slides ()
  "Build `orgacle--slides' and reset navigation to the first slide.
Sets `orgacle--slides' from `orgacle--build-slides' and
`orgacle--slide-index' to 0.  Called once per presentation -- by
`orgacle-run', and directly by tests that exercise navigation without
starting a full presentation -- after which `orgacle-top',
`orgacle-next-page', `orgacle-previous-page' and `orgacle-jump-to-page'
are index arithmetic over the vector it builds."
  (setq orgacle--slides (orgacle--build-slides))
  (setq orgacle--slide-index 0))

(defun orgacle--goto-slide (index)
  "Move to slide INDEX of `orgacle--slides' and present it.
Sets `orgacle--slide-index' and `orgacle-page-number' from INDEX --
the latter is always the former plus one, so it cannot drift the way
independent increments and decrements used to -- widens the buffer,
moves point to the slide's marker, and calls `orgacle-current-page'
exactly once.  That single call is what makes jumping any number of
slides cost one redisplay instead of one per slide skipped over.
Does nothing when `orgacle--slides' is empty, which an Org buffer with
no headings at all produces; there is then no slide to move to."
  (when (> (length orgacle--slides) 0)
    (setq orgacle--slide-index index)
    (setq orgacle-page-number (1+ index))
    (widen)
    (goto-char (aref orgacle--slides index))
    (orgacle-current-page)))

(defun orgacle-jump-to-page (num)
  "Jump directly to page NUM of the presentation.
NUM is clamped to the deck: below 1 goes to the first slide, above the
last slide goes to the last one."
  (interactive "npage number: ")
  (orgacle--goto-slide
   (max 0 (min (1- (length orgacle--slides)) (1- num)))))

(defun orgacle-current-page ()
  "Present the current outline heading as a slide."
  (interactive)
  (when orgacle-aux-window
    (delete-window orgacle-aux-window)
    (setq orgacle-aux-window nil))
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
  (if orgacle-notes-buffer
      (with-current-buffer orgacle-notes-buffer
	(goto-char (point-min))))
  (orgacle--goto-slide 0))

(defun orgacle-next-page ()
  "Advance to the next slide and present it.
Past the last slide, nothing moves and the last slide stays on
display."
  (interactive)
  (orgacle--goto-slide
   (min (1- (length orgacle--slides)) (1+ orgacle--slide-index))))

(defun orgacle-previous-page ()
  "Present the previous slide.
Before the first slide, nothing moves and the first slide stays on
display."
  (interactive)
  (orgacle--goto-slide (max 0 (1- orgacle--slide-index))))

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
