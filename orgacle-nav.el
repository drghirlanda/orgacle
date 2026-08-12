;;; orgacle-nav.el --- Slide navigation for Orgacle  -*- lexical-binding: t; -*-

;; This file is part of Orgacle.  See orgacle.el for the package header,
;; copyright and licence.

;;; Commentary:

;; Slide navigation for Orgacle: moving between pages and subheadings,
;; and presenting the current outline heading as a slide.

;;; Code:

(require 'org)
(require 'orgacle-core)

;; TEMPORARY: `orgacle-current-page' calls into subsystems that do not
;; yet live in a module this file requires -- most of them (still in
;; orgacle.el) belong to src-block, media and notes handling that
;; Task 2 does not touch, and `orgacle-slide-in-effect' moves to
;; orgacle-fontify.el in this same task, which this file deliberately
;; does not require, to avoid a sibling-module dependency cycle.
;; Task 5 removes these declarations when it replaces the direct
;; calls with the shared `orgacle-page-hook'.
(declare-function orgacle-toggle-hide-src-blocks "orgacle-src" (&optional arg))
(declare-function orgacle-show-file-auto "orgacle-media" ())
(declare-function orgacle-slide-in-effect "orgacle-fontify" ())
(declare-function orgacle-show-indicators-maybe "orgacle-media" ())
(declare-function orgacle-position-notes "orgacle" ())

(defun orgacle-get-frame-level ()
  "Get the heading level to show as different frames."
  (interactive)
  (save-excursion
    (save-restriction
      (widen)
      (goto-char (point-min))
      (if (re-search-forward
           "^#\\+ORGACLE_FRAME_LEVEL:[ \t]*\\(.*?\\)[ \t]*$" nil t)
          (string-to-number (match-string 1))
        orgacle-frame-level))))

(defun orgacle-get-mode-line ()
  "Get the presentation-specific mode-line."
  (interactive)
  (save-excursion
    (save-restriction
      (widen)
      (goto-char (point-min))
      (if (re-search-forward
           "^#\\+ORGACLE_MODE_LINE:[ \t]*\\(.*?\\)[ \t]*$" nil t)
          (car (read-from-string (match-string 1)))
        orgacle-mode-line))))

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
	(orgacle-show-file-auto)
	(orgacle-slide-in-effect)
	(orgacle-show-indicators-maybe)
	(orgacle-position-notes))
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
