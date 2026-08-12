;;; orgacle-src.el --- Source-block interaction for Orgacle  -*- lexical-binding: t; -*-

;; This file is part of Orgacle.  See orgacle.el for the package header,
;; copyright and licence.

;;; Commentary:

;; Source-block interaction for Orgacle: moving between source blocks,
;; flashing the cursor, and hiding or showing source block bodies.

;;; Code:

(require 'orgacle-core)

(defun orgacle-setup-src-edit ()
  "Switch to a box cursor for editing a source block in place.
Added to `org-src-mode-hook' by `orgacle-mode'."
  (setq cursor-type 'box))

(defun orgacle-flash-cursor ()
  "Briefly show a hollow cursor, then restore the default cursor."
  (setq cursor-type 'hollow)
  (sit-for 0.5)
  (setq cursor-type nil))

(defun orgacle-next-src-block (&optional arg)
  "Move to the next source block and flash the cursor.
ARG is passed to `org-babel-next-src-block'."
  (interactive "P")
  (org-babel-next-src-block arg)
  (orgacle-flash-cursor))

(defun orgacle-previous-src-block (&optional arg)
  "Move to the previous source block and flash the cursor.
ARG is passed to `org-babel-previous-src-block'."
  (interactive "P")
  (org-babel-previous-src-block arg)
  (orgacle-flash-cursor))

(defun orgacle-toggle-hide-src-blocks (&optional arg)
  "Toggle the visibility of source block bodies.
With ARG non-nil, toggle only the source block at point; otherwise
toggle every source block in the buffer."
  (interactive "P")
  (cl-labels
      ((boundaries
        ()
        (let ((head (org-babel-where-is-src-block-head)))
          (if head
              (save-excursion
                (goto-char head)
                (looking-at org-babel-src-block-regexp)
                (list (match-beginning 5) (match-end 5)))
            (error "No source block to hide at %d" (point)))))
       (toggle
        ()
        (cl-destructuring-bind (beg end) (boundaries)
          (let ((ovs (cl-remove-if-not
                      (lambda (ov) (overlay-get ov 'orgacle-hidden-src-block))
                      (overlays-at beg))))
            (if ovs
                (unless (and orgacle-src-block-toggle-state
                             (eq orgacle-src-block-toggle-state :hide))
                  (progn
                    (mapc #'delete-overlay ovs)
                    (setq orgacle-overlays
                          (cl-set-difference orgacle-overlays ovs))))
              (unless (and orgacle-src-block-toggle-state
                           (eq orgacle-src-block-toggle-state :show))
                (progn
                  (push (make-overlay beg end) orgacle-overlays)
                  (overlay-put (car orgacle-overlays)
                               'orgacle-hidden-src-block t)
                  (overlay-put (car orgacle-overlays)
                               'invisible 'orgacle-hide))))))))
    (if arg (toggle)               ; only toggle the current src block
      (save-excursion              ; toggle all source blocks
        (goto-char (point-min))
        (while (re-search-forward org-babel-src-block-regexp nil t)
          (goto-char (1- (match-end 5)))
          (toggle))))
    (redraw-display)))

(defun orgacle-toggle-hide-src-block (&optional _arg)
  "Toggle the visibility of the source block at point.
ARG is accepted for the same calling convention as
`orgacle-toggle-hide-src-blocks' but is not otherwise used: this
command always toggles the block at point regardless of ARG."
  (interactive "P")
  (orgacle-toggle-hide-src-blocks t))

(provide 'orgacle-src)
;;; orgacle-src.el ends here
