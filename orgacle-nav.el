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
(declare-function orgacle-toggle-hide-src-blocks "orgacle-src" (&optional arg))

(defun orgacle-goto-top-level ()
  "Go to the current top level heading containing point."
  (interactive)
  (unless (org-at-heading-p) (outline-previous-heading))
  (let ((level (ignore-errors (org-reduced-level (org-current-level)))))
    (when (and level (> level orgacle-frame-level))
      (org-up-heading-all (- level orgacle-frame-level)))))

(defun orgacle-jump-to-page (num)
  "Jump directly to page NUM of the presentation."
  (interactive "npage number: ")
  (orgacle-top)
  (dotimes (_ (1- num)) (orgacle-next-page)))

(defun orgacle-current-page (&optional backward)
  "Present the current outline heading.
BACKWARD, if non-nil, means a leading \"TITLE PAGE\" heading is
skipped by moving to the previous page instead of the next one, so
that skipping moves in the direction the user is already navigating."
  (interactive)
  (when orgacle-aux-window
    (delete-window orgacle-aux-window)
    (setq orgacle-aux-window nil))
  (if (org-current-level)
      (progn
	(orgacle-goto-top-level)
	;; skipe a TITLE PAGE heading, used for introductory speaker notes
	(if (string= (downcase (org-entry-get nil "ITEM")) "title page")
	    (if backward
		(orgacle-previous-page t)
	      (orgacle-next-page t)))
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
  "Present the first outline heading."
  (interactive)
  (widen)
  (goto-char (point-min))
  (setq orgacle-page-number 1)
  ;; rewind notes buffer if present
  (if orgacle-notes-buffer
      (with-current-buffer orgacle-notes-buffer
	(goto-char (point-min))))
  (orgacle-current-page))

(defun orgacle-next-page (&optional skip)
  "Advance to the next outline heading and present it.
With SKIP non-nil the page counter advances but nothing is displayed,
which is how a TITLE PAGE heading is stepped over."
  (interactive)
  (orgacle-goto-top-level)
  (widen)
  (when (if (< (or (ignore-errors (org-reduced-level (org-current-level))) 0)
               orgacle-frame-level)
            (outline-next-heading)
          (org-get-next-sibling))
    (cl-incf orgacle-page-number))
  (unless skip
    (orgacle-current-page)))

(defun orgacle-previous-page (&optional _skip)
  "Present the previous outline heading.
SKIP is accepted for the same calling convention as
`orgacle-next-page' but currently has no effect: this command
always redisplays the destination page regardless of SKIP."
  (interactive)
  (orgacle-goto-top-level)
  (widen)
  (org-content)
  (if (< (or (ignore-errors (org-reduced-level (org-current-level))) 0)
         orgacle-frame-level)
      (outline-previous-heading)
    (org-get-previous-sibling))
  (when (> orgacle-page-number 1)
    (cl-decf orgacle-page-number))
  (orgacle-current-page t))

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
