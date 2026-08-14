;;; orgacle-src.el --- Source-block interaction for Orgacle  -*- lexical-binding: t; -*-

;; This file is part of Orgacle.  See orgacle.el for the package header,
;; copyright and licence.

;;; Commentary:

;; Source-block interaction for Orgacle: moving between source blocks,
;; flashing the cursor, and hiding or showing source block bodies.

;;; Code:

(require 'orgacle-core)
(require 'org-src)

;; `orgacle-refresh' lives in orgacle-fontify.el, a sibling module this
;; file deliberately does not require -- the same restriction every
;; other cross-file reference in this package follows; see
;; orgacle-nav.el's own declaration of `orgacle-toggle-hide-src-blocks'
;; for the fuller explanation.  `orgacle--refresh-after-src-edit' below
;; needs it so a live speaker-notes buffer does not go stale after an
;; edit made through `org-edit-src-code'; see that function's own
;; docstring.
(declare-function orgacle-refresh "orgacle-fontify" ())

(defun orgacle-setup-src-edit ()
  "Switch to a box cursor for editing a source block in place.
Added to `org-src-mode-hook' by `orgacle-mode'."
  (setq cursor-type 'box))

(defun orgacle--refresh-after-src-edit (&rest _args)
  "Rebuild a live notes buffer once `org-edit-src-exit' has returned.
Added as `:after' advice on `org-edit-src-exit' below, since that
function has no hook or other extension point of its own to add this
to, unlike every other content-editing path in the package --
`orgacle-edit-text's own exit key is bound directly to `orgacle-refresh',
and running a source block already reaches it through
`org-babel-after-execute-hook'.  Without this, a source block edited
inside a \"Speaker notes\" subtree left the speaker-notes buffer
showing the pre-edit text until the presenter separately pressed `r'
or `g', or navigated away and back -- confirmed directly before
writing this fix.  \(A heading is not among the things that can go
stale this way: `org-edit-src-exit' itself unconditionally
comma-escapes any line that would otherwise read as a heading or
keyword on every write-back, for any source language, so a source
block cannot newly become or reveal one through this path -- also
confirmed directly.\)

`:after' advice, rather than a key rebound only inside the edit
buffer, so this also covers exiting via `M-x org-edit-src-exit'
directly, not only the presentation's own `e' key.  ARGS is unused;
`org-edit-src-exit' itself takes none, but `:after' advice always
receives whatever the advised function was called with.  Guarded on
`major-mode', checked only once `org-edit-src-exit' has already
returned: that function's own last act before returning is switching
back to the source buffer \(`org-src-switch-to-buffer', called before
the edited text is written back\), so `current-buffer' here already
and correctly names the presentation buffer the edited block belongs
to, not the just-killed edit buffer.  Ordinary Org editing outside a
presentation, or editing in a buffer whose presentation has since
ended, leaves `major-mode' something other than `orgacle-mode' here,
so this stays a no-op for both.

Calling `orgacle-refresh' here can surface a separate, pre-existing
defect this fix does not cause but does make somewhat more reachable:
editing a source block inside a slide's own \"Speaker notes\" subtree,
when that subtree is the very last heading in the whole presentation
buffer, and exiting, un-hides it on screen -- exactly as plain `r'/`g'
already do in that same situation, with no source-block editing
involved at all.  See
`orgacle-test-refresh-keeps-trailing-speaker-notes-hidden'
in test/orgacle-test.el for the reproduction and root cause; out of
scope for this fix, which is only about rebuilding a live notes buffer
on this exit path the way every other content-editing path already
does."
  (when (eq major-mode 'orgacle-mode)
    (orgacle-refresh)))

(advice-add 'org-edit-src-exit :after #'orgacle--refresh-after-src-edit)

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
